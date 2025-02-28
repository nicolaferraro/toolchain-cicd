#!/usr/bin/env bash

set -ex

WAS_ALREADY_PAIRED_FILE=/tmp/toolchain_e2e_already_paired

get_repo() {
    PAIRED=false
    if [[ -z ${PROVIDED_REPOSITORY_PATH} ]]; then
        REPOSITORY_PATH="/tmp/codeready-toolchain/${REPOSITORY_NAME}"
        rm -rf ${REPOSITORY_PATH}
        # clone
        git clone https://github.com/codeready-toolchain/${REPOSITORY_NAME}.git ${REPOSITORY_PATH}

        pair_repo_if_needed
    else
        REPOSITORY_PATH=${PROVIDED_REPOSITORY_PATH}
    fi

}

set_tags() {
    TAGS=${DATE_SUFFIX}
    COMMIT_ID_SUFFIX=${PULL_PULL_SHA:0:7}

    if [[ -n "${CI}${CLONEREFS_OPTIONS}" ]]; then
        if [[ -n ${GITHUB_ACTIONS} ]]; then
            OPERATOR_REPO_NAME=${GITHUB_REPOSITORY##*/}
            TAGS=from.${OPERATOR_REPO_NAME}.PR${PULL_NUMBER}.${COMMIT_ID_SUFFIX}
        else
            AUTHOR=$(jq -r '.refs[0].pulls[0].author' <<< ${CLONEREFS_OPTIONS} | tr -d '[:space:]')
            PULL_PULL_SHA=${PULL_PULL_SHA:-$(jq -r '.refs[0].pulls[0].sha' <<< ${CLONEREFS_OPTIONS} | tr -d '[:space:]')}
            TAGS="from.$(echo ${REPO_NAME} | sed 's/"//g').PR${PULL_NUMBER}.${COMMIT_ID_SUFFIX}"
        fi
    fi
#    can be used only when the operator CSV doesn't bundle the environment information, but now we want to build bundle for both operators
#    if is_provided_or_paired; then
        BUNDLE_AND_INDEX_TAG=${TAGS}
#    fi
}

push_image() {
    GIT_COMMIT_ID=$(git --git-dir=${REPOSITORY_PATH}/.git --work-tree=${REPOSITORY_PATH} rev-parse --short HEAD)
    IMAGE_LOC=quay.io/codeready-toolchain/${REPOSITORY_NAME}:${GIT_COMMIT_ID}
    if is_provided_or_paired; then
        make -C ${REPOSITORY_PATH} docker-push QUAY_NAMESPACE=${QUAY_NAMESPACE} IMAGE_TAG=${TAGS}
        IMAGE_LOC=quay.io/${QUAY_NAMESPACE}/${REPOSITORY_NAME}:${TAGS}
    fi
}

is_provided_or_paired() {
    [[ -n ${PROVIDED_REPOSITORY_PATH} ]] || [[ ${PAIRED} == true ]]
}

pair_repo_if_needed() {
    if [[ -n ${GITHUB_ACTIONS} ]]; then
        PR_REPO_NAME=${GITHUB_REPOSITORY##*/}
    else
        PR_REPO_NAME=$(echo ${REPO_NAME} | sed 's/"//')
    fi


    if [[ -n "${CI}${CLONEREFS_OPTIONS}" ]] && [[ ${PR_REPO_NAME} == "toolchain-e2e" ]]; then
        if [[ -n ${CLONEREFS_OPTIONS} ]]; then
            # get branch ref of the fork the PR was created from
            AUTHOR_LINK=$(jq -r '.refs[0].pulls[0].author_link' <<< ${CLONEREFS_OPTIONS} | tr -d '[:space:]')
            PULL_PULL_SHA=${PULL_PULL_SHA:-$(jq -r '.refs[0].pulls[0].sha' <<< ${CLONEREFS_OPTIONS} | tr -d '[:space:]')}
            echo "using author link ${AUTHOR_LINK}"
            echo "using pull sha ${PULL_PULL_SHA}"
            # get branch ref of the fork the PR was created from
            REPO_URL=${AUTHOR_LINK}/toolchain-e2e
            echo "branches of ${REPO_URL} - trying to detect the branch name we should use for pairing."
            curl ${REPO_URL}.git/info/refs?service=git-upload-pack --output -
            GET_BRANCH_NAME=$(curl ${REPO_URL}.git/info/refs?service=git-upload-pack --output - 2>/dev/null | grep -a ${PULL_PULL_SHA} || true)
            if [[ $(echo ${GET_BRANCH_NAME} | wc -l) > 1 ]]; then \
                echo "###################################  ERROR DURING THE E2E TEST SETUP  ###################################
There were found more branches with the same latest commit '${PULL_PULL_SHA}' in the repo ${REPO_URL} - see:

${GET_BRANCH_NAME}

It's not possible to detect the correct branch this PR is made for.
Please delete the unrelated branch from your fork and rerun the e2e tests.
Note: If you have already deleted the unrelated branch from your fork, it can take a few hours before the
      github api is updated so the e2e tests may still fail with the same error until then.
##########################################################################################################"
                exit 1
            fi
            BRANCH_REF=$(echo ${GET_BRANCH_NAME} | awk '{print $2}')
            echo "detected branch ref ${BRANCH_REF}"
            # retrieve the branch name
            BRANCH_NAME=$(echo ${BRANCH_REF} | awk -F'/' '{print $3}')
        else
            AUTHOR_LINK=https://github.com/${AUTHOR}
            BRANCH_REF=refs/heads/${GITHUB_HEAD_REF}
            BRANCH_NAME=${GITHUB_HEAD_REF}
            REPO_URL=${AUTHOR_LINK}/toolchain-e2e
        fi

        if [[ -n "${BRANCH_REF}" ]]; then \
            # check if a branch with the same ref exists in the user's fork of ${REPOSITORY_NAME} repo
            echo "branches of ${AUTHOR_LINK}/${REPOSITORY_NAME} - checking if there is a branch ${BRANCH_REF} we could pair with."
            curl ${AUTHOR_LINK}/${REPOSITORY_NAME}.git/info/refs?service=git-upload-pack --output -
            REMOTE_E2E_BRANCH=$(curl ${AUTHOR_LINK}/${REPOSITORY_NAME}.git/info/refs?service=git-upload-pack --output - 2>/dev/null | grep -a "${BRANCH_REF}$" | awk '{print $2}')
            echo "branch ref of the user's fork: \"${REMOTE_E2E_BRANCH}\" - if empty then not found"
            # check if the branch with the same name exists, if so then merge it with master and use the merge branch, if not then use master \
            if [[ -n "${REMOTE_E2E_BRANCH}" ]]; then \
                if [[ -f ${WAS_ALREADY_PAIRED_FILE} ]]; then \
                    echo "####################################  ERROR WHILE TRYING TO PAIR PRs  ####################################
There was an error while trying to pair this e2e PR with ${AUTHOR_LINK}/${REPOSITORY_NAME}@${BRANCH_REF}
The reason is that there was already detected a branch from another repo this PR could be paired with - see:

$(cat ${WAS_ALREADY_PAIRED_FILE})

It's not possible to pair a PR with multiple branches from other repositories.
Please delete one of the branches from your fork and rerun the e2e tests
Note: If you have already deleted one of the branches from your fork, it can take a few hours before the
      github api is updated so the e2e tests may still fail with the same error until then.
##########################################################################################################"
                    exit 1
                fi

                git config --global user.email "devtools@redhat.com"
                git config --global user.name "Devtools"

                echo -e "repository: ${AUTHOR_LINK}/${REPOSITORY_NAME} \nbranch: ${BRANCH_NAME}" > ${WAS_ALREADY_PAIRED_FILE}
                # add the user's fork as remote repo
                git --git-dir=${REPOSITORY_PATH}/.git --work-tree=${REPOSITORY_PATH} remote add external ${AUTHOR_LINK}/${REPOSITORY_NAME}.git
                # fetch the branch
                git --git-dir=${REPOSITORY_PATH}/.git --work-tree=${REPOSITORY_PATH} fetch external ${BRANCH_REF}
                # merge the branch with master
                git --git-dir=${REPOSITORY_PATH}/.git --work-tree=${REPOSITORY_PATH} merge --allow-unrelated-histories --no-commit FETCH_HEAD

                PAIRED=true
            fi
        fi
    fi
}


install_operator() {
    DISPLAYNAME=$(echo ${OPERATOR_NAME} | tr '-' ' ' | awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')

    GIT_COMMIT_ID=`git --git-dir=${REPOSITORY_PATH}/.git --work-tree=${REPOSITORY_PATH} rev-parse --short HEAD`
    INDEX_IMAGE=quay.io/${QUAY_NAMESPACE}/${INDEX_IMAGE_NAME}:${BUNDLE_AND_INDEX_TAG}
    CATALOGSOURCE_NAME=source-${OPERATOR_NAME}-${GIT_COMMIT_ID}
    SUBSCRIPTION_NAME=subscription-${OPERATOR_NAME}-${GIT_COMMIT_ID}

    # if the operator was already installed in the cluster, then delete all OLM related resources
    for SUB in $(oc get Subscription -n ${NAMESPACE} -o name | grep  "subscription-${OPERATOR_NAME}"); do
        oc delete ${SUB} -n ${NAMESPACE}
        sleep 5
    done
    for CAT in $(oc get CatalogSource -n ${NAMESPACE} -o name | grep  "source-${OPERATOR_NAME}"); do
        oc delete ${CAT} -n ${NAMESPACE}
        sleep 5
    done
    for CSV in $(oc get csv -n ${NAMESPACE} -o name | grep  "${OPERATOR_NAME}"); do
        oc delete ${CSV} -n ${NAMESPACE}
        sleep 5
    done

    INSTALL_OBJECTS="apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: og-${OPERATOR_NAME}
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: alpha
  installPlanApproval: Automatic
  name: ${OPERATOR_NAME}
  source: ${CATALOGSOURCE_NAME}
  sourceNamespace: ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOGSOURCE_NAME}
  namespace: ${NAMESPACE}
spec:
  sourceType: grpc
  image: ${INDEX_IMAGE}
  displayName: ${DISPLAYNAME}
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 1m0s"
    echo "objects to be created in order to install operator"
    cat <<EOF | oc apply -f -
${INSTALL_OBJECTS}
EOF

wait_until_is_installed
}

wait_until_is_installed() {
    set -e
    NEXT_WAIT_TIME=0
    while [[ -z `oc get crd | grep ${EXPECT_CRD} || true` ]]; do
        if [[ ${NEXT_WAIT_TIME} -eq 100 ]]; then
           echo "reached timeout of waiting for CRD ${EXPECT_CRD} to be available in the cluster - see following info for debugging:"
           echo "================================ CatalogSource =================================="
           oc get catalogsource ${CATALOGSOURCE_NAME} -n ${NAMESPACE} -o yaml
           echo "================================ CatalogSource Pod Logs =================================="
           oc logs `oc get pods -l "olm.catalogSource=${CATALOGSOURCE_NAME#*/}" -n ${NAMESPACE} -o name` -n ${NAMESPACE}
           echo "================================ Subscription =================================="
           oc get subscription ${SUBSCRIPTION_NAME} -n ${NAMESPACE} -o yaml
           echo "================================ InstallPlans =================================="
           oc get installplans -n ${NAMESPACE} -o yaml
           exit 1
        fi
        echo "$(( NEXT_WAIT_TIME++ )). attempt of waiting for CRD ${EXPECT_CRD} to be available in the cluster"
        sleep 1
    done
}
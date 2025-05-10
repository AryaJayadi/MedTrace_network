#!/bin/bash
#
# Script to deploy a Go chaincode to the MedTrace network.
# This script automates the steps based on the Hyperledger Fabric chaincode lifecycle.
#

# --- Configuration - Adjust these as needed or use command-line flags ---
DEFAULT_CC_NAME="medtracecc"
DEFAULT_CC_VERSION="1.0"
DEFAULT_CC_SEQUENCE="1"
# Path to your Go chaincode source code on your host machine
# Assumes a directory structure like:
# ./deploy_chaincode.sh
# ./chaincode_src/medtrace-go/  <-- Your chaincode is here
DEFAULT_CC_SRC_PATH_HOST="../chaincode_src/medtrace-go"
# Path where chaincode will be copied/mounted inside the CLI container
DEFAULT_CC_PATH_CLI="/opt/gopath/src/github.com/chaincode"
DEFAULT_CHANNEL_NAME="medtrace"
# Optional: JSON string for Init function arguments, e.g., '{"Args":["InitLedger"]}'
# If empty or not provided, --isInit will not be called.
DEFAULT_INIT_FCN_ARGS=""
# --- End Configuration ---

# Script execution flags
VERBOSE=false

# CLI container name (must match your medtrace_network.sh setup)
CLI_CONTAINER_NAME="cli.medtrace.com"

# Orderer details (as seen from within CLI container)
ORDERER_ADDRESS="orderer.medtrace.com:7050"
# The ORDERER_CA_CLI variable is expected to be set as an environment variable
# inside the cli.medtrace.com container by your docker-compose.yaml.
# Its value is typically:
# /opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/ordererOrganizations/medtrace.com/orderers/orderer.medtrace.com/tls/ca.crt

# --- Helper Functions ---

# Function to print script usage
printHelp() {
  echo "Usage: ./deploy_chaincode.sh [OPTIONS]"
  echo
  echo "Automates the deployment of a Go chaincode to the MedTrace network."
  echo
  echo "Options:"
  echo "  -ccn <name>         Chaincode name (Default: ${DEFAULT_CC_NAME})"
  echo "  -ccv <version>      Chaincode version (Default: ${DEFAULT_CC_VERSION})"
  echo "  -ccs <sequence>     Chaincode sequence number (Default: ${DEFAULT_CC_SEQUENCE})"
  echo "  -ccp <host_path>    Path to chaincode source on host machine (Default: ${DEFAULT_CC_SRC_PATH_HOST})"
  echo "  -ccicli <cli_path>  Path where chaincode will be copied inside CLI (Default: ${DEFAULT_CC_PATH_CLI})"
  echo "  -c <channel_name>   Channel name (Default: ${DEFAULT_CHANNEL_NAME})"
  echo "  -cci <init_args>    JSON string for Init function arguments (e.g., '{\"Args\":[\"InitLedger\"]}')."
  echo "                      If empty, --isInit will not be called."
  echo "  -verbose            Enable verbose output of commands executed in CLI."
  echo "  -h, --help          Print this help message."
  echo
  echo "Prerequisites:"
  echo "  1. Your Go chaincode source directory (e.g., specified by -ccp) must contain a 'vendor' folder."
  echo "     Run 'go mod tidy && go mod vendor' in your chaincode directory."
  echo "  2. The MedTrace network (including '${CLI_CONTAINER_NAME}') must be running."
  echo
  echo "Example: ./deploy_chaincode.sh -ccn mycc -ccv 1.1 -ccs 2 -ccp ../mycc_source -cci '{\"Args\":[\"InitLedger\"]}'"
}

# Function to execute a command inside the CLI container
# Usage: execCli "command_to_run"
# Returns the exit code of the command. Output is captured.
execCli() {
  local CMD="$1"
  local OUTPUT
  if [ "$VERBOSE" == "true" ]; then
    echo "VERBOSE: Executing in ${CLI_CONTAINER_NAME}: ${CMD}"
  fi
  OUTPUT=$(docker exec "${CLI_CONTAINER_NAME}" bash -c "${CMD}" 2>&1)
  local EXIT_CODE=$?
  if [ "$VERBOSE" == "true" ] || [ ${EXIT_CODE} -ne 0 ]; then
    echo "Output from CLI:"
    echo "${OUTPUT}"
  fi
  return ${EXIT_CODE}
}

# Function to execute a command as a specific org inside the CLI container
# Usage: execCliAsOrg ORG_NUM "command_to_run"
# Returns the exit code of the command. Output is captured.
execCliAsOrg() {
  local ORG_NUM=$1
  local CMD_TO_RUN=$2
  local PEER_PORT # Declared local to the function
  case $ORG_NUM in
  1) PEER_PORT=7051 ;;
  2) PEER_PORT=8051 ;;
  3) PEER_PORT=9051 ;;
  4) PEER_PORT=10051 ;;
  *)
    echo "ERROR: Invalid Org num: ${ORG_NUM}" >&2
    return 1
    ;;
  esac

  # Environment variables to set the context for the peer CLI commands
  # ORDERER_CA_CLI is used from the CLI container's environment directly
  local ENV_VARS_CMD="
    export CORE_PEER_LOCALMSPID=\"Org${ORG_NUM}MSP\";
    export CORE_PEER_TLS_ROOTCERT_FILE=\"/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org${ORG_NUM}.medtrace.com/peers/peer0.org${ORG_NUM}.medtrace.com/tls/ca.crt\";
    export CORE_PEER_MSPCONFIGPATH=\"/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org${ORG_NUM}.medtrace.com/users/Admin@org${ORG_NUM}.medtrace.com/msp\";
    export CORE_PEER_ADDRESS=\"peer0.org${ORG_NUM}.medtrace.com:${PEER_PORT}\";
  "
  # Informational message about context switch (will be part of the command output if VERBOSE)
  local INFO_CMD="echo 'INFO: CLI context switched to Org${ORG_NUM} targeting \${CORE_PEER_ADDRESS}';"

  local FULL_CMD="${ENV_VARS_CMD} ${INFO_CMD} ${CMD_TO_RUN}"

  execCli "${FULL_CMD}"
  return $?
}

# --- Parse Command Line Arguments ---
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
  -ccn)
    CC_NAME="$2"
    shift
    shift
    ;;
  -ccv)
    CC_VERSION="$2"
    shift
    shift
    ;;
  -ccs)
    CC_SEQUENCE="$2"
    shift
    shift
    ;;
  -ccp)
    CC_SRC_PATH_HOST="$2"
    shift
    shift
    ;;
  -ccicli)
    CC_PATH_CLI="$2"
    shift
    shift
    ;;
  -c)
    CHANNEL_NAME="$2"
    shift
    shift
    ;;
  -cci)
    INIT_FCN_ARGS="$2"
    shift
    shift
    ;;
  -verbose)
    VERBOSE=true
    shift
    ;;
  -h | --help)
    printHelp
    exit 0
    ;;
  *)
    echo "ERROR: Unknown option $key" >&2
    printHelp
    exit 1
    ;;
  esac
done

# Set defaults if not provided by arguments
CC_NAME="${CC_NAME:-${DEFAULT_CC_NAME}}"
CC_VERSION="${CC_VERSION:-${DEFAULT_CC_VERSION}}"
CC_SEQUENCE="${CC_SEQUENCE:-${DEFAULT_CC_SEQUENCE}}"
CC_SRC_PATH_HOST="${CC_SRC_PATH_HOST:-${DEFAULT_CC_SRC_PATH_HOST}}"
CC_PATH_CLI="${CC_PATH_CLI:-${DEFAULT_CC_PATH_CLI}}"
CHANNEL_NAME="${CHANNEL_NAME:-${DEFAULT_CHANNEL_NAME}}"
INIT_FCN_ARGS="${INIT_FCN_ARGS:-${DEFAULT_INIT_FCN_ARGS}}"
CC_LABEL="${CC_NAME}_${CC_VERSION}" # Used for packaging and identifying the chaincode
CC_PKG_FILE="${CC_LABEL}.tar.gz"    # Chaincode package file name (will be created inside CLI)

# --- Main Deployment Logic ---

echo "INFO: Starting chaincode deployment with the following parameters:"
echo "  Chaincode Name:     ${CC_NAME}"
echo "  Chaincode Version:  ${CC_VERSION}"
echo "  Chaincode Sequence: ${CC_SEQUENCE}"
echo "  Chaincode Label:    ${CC_LABEL}"
echo "  Host Source Path:   ${CC_SRC_PATH_HOST}"
echo "  CLI Target Path:    ${CC_PATH_CLI}"
echo "  Channel Name:       ${CHANNEL_NAME}"
if [ -n "${INIT_FCN_ARGS}" ]; then
  echo "  Init Function Args: '${INIT_FCN_ARGS}' (will use --init-required and --isInit)"
else
  echo "  Init Function:      Not specified (will not use --init-required or --isInit)"
fi
echo "  Verbose Mode:       ${VERBOSE}"
echo "-------------------------------------------------------------------"

# Step 0: Check prerequisites
echo "INFO: [Step 0] Checking prerequisites..."
if [ ! -d "${CC_SRC_PATH_HOST}/vendor" ]; then
  echo "ERROR: Chaincode source directory '${CC_SRC_PATH_HOST}' does not appear to be vendored (missing 'vendor' sub-directory)." >&2
  echo "Please run 'go mod tidy && go mod vendor' in your chaincode directory first." >&2
  exit 1
fi
echo "INFO: Chaincode vendoring check passed."

if ! docker ps -f name="^/${CLI_CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "${CLI_CONTAINER_NAME}"; then
  echo "ERROR: CLI container '${CLI_CONTAINER_NAME}' is not running. Please start the MedTrace network using './medtrace_network.sh up'." >&2
  exit 1
fi
echo "INFO: CLI container '${CLI_CONTAINER_NAME}' is running."
echo "-------------------------------------------------------------------"

# Step 0.1: Copy chaincode source to CLI container
echo "INFO: [Step 0.1] Copying chaincode from host ('${CC_SRC_PATH_HOST}') to '${CLI_CONTAINER_NAME}:${CC_PATH_CLI}'..."
# Remove existing target directory in CLI to ensure clean copy
execCli "rm -rf ${CC_PATH_CLI}"
docker cp "${CC_SRC_PATH_HOST}" "${CLI_CONTAINER_NAME}:${CC_PATH_CLI}"
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to copy chaincode source to CLI container." >&2
  exit 1
fi
echo "INFO: Chaincode source copied successfully."
echo "-------------------------------------------------------------------"

# Step 1: Package Chaincode (executed inside CLI container)
echo "INFO: [Step 1] Packaging chaincode '${CC_NAME}' version '${CC_VERSION}'..."
# The package will be created in the CLI container's current working directory (/opt/gopath/src/github.com/hyperledger/fabric/peer)
PACKAGE_CMD="peer lifecycle chaincode package ${CC_PKG_FILE} --path ${CC_PATH_CLI} --lang golang --label ${CC_LABEL}"
execCli "${PACKAGE_CMD}"
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to package chaincode." >&2
  exit 1
fi
echo "INFO: Chaincode packaged successfully as '${CC_PKG_FILE}' (inside CLI container)."
echo "-------------------------------------------------------------------"

# Step 2: Install Chaincode on all Peers and Get Package ID
echo "INFO: [Step 2] Installing chaincode package '${CC_PKG_FILE}' on all peers..."
CC_PACKAGE_ID="" # Will be populated after installing on the first peer

for org_num in 1 2 3 4; do
  echo "INFO: Installing chaincode on peer0.org${org_num}.medtrace.com..."
  INSTALL_CMD="peer lifecycle chaincode install /opt/gopath/src/github.com/hyperledger/fabric/peer/${CC_PKG_FILE}" # Use absolute path to package
  execCliAsOrg "${org_num}" "${INSTALL_CMD}"
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to install chaincode on peer0.org${org_num}.medtrace.com." >&2
    exit 1
  fi

  # Retrieve and store the Package ID after installing on the first peer (Org1)
  if [ "${org_num}" -eq 1 ] && [ -z "${CC_PACKAGE_ID}" ]; then
    echo "INFO: Querying installed chaincode on Org1 to retrieve Package ID..."
    QUERY_INSTALLED_CMD="peer lifecycle chaincode queryinstalled"

    OUTPUT_QUERY_INSTALLED_FULL=$(execCliAsOrg "1" "${QUERY_INSTALLED_CMD}")
    INSTALL_QUERY_EXIT_CODE=$? # Capture exit code of execCliAsOrg

    if [ ${INSTALL_QUERY_EXIT_CODE} -ne 0 ]; then
      echo "ERROR: Failed to query installed chaincodes on Org1." >&2
      exit 1
    fi

    # Filter out potential INFO lines from execCliAsOrg before parsing
    OUTPUT_QUERY_INSTALLED=$(echo "${OUTPUT_QUERY_INSTALLED_FULL}" | grep -v "INFO: CLI context switched to Org")

    if [ "$VERBOSE" == "true" ]; then
      echo "VERBOSE: Raw output of queryinstalled on Org1:"
      echo "${OUTPUT_QUERY_INSTALLED_FULL}"
      echo "VERBOSE: Filtered output for parsing Package ID:"
      echo "${OUTPUT_QUERY_INSTALLED}"
    fi

    CC_PACKAGE_ID=$(echo "${OUTPUT_QUERY_INSTALLED}" | grep "Package ID: ${CC_LABEL}" | sed -n 's/Package ID: //; s/, Label:.*$//;p')

    if [ -z "${CC_PACKAGE_ID}" ]; then
      echo "ERROR: Could not automatically parse Package ID for label '${CC_LABEL}' from Org1's peer." >&2
      echo "Full output from queryinstalled on Org1:"
      echo "${OUTPUT_QUERY_INSTALLED_FULL}"
      exit 1
    fi
    echo "INFO: Retrieved Package ID: ${CC_PACKAGE_ID}"
  fi
done
echo "INFO: Chaincode installed on all peers successfully."
echo "-------------------------------------------------------------------"

# Step 3: Approve Chaincode Definition for Each Organization
echo "INFO: [Step 3] Approving chaincode definition for all organizations..."
for org_num in 1 2 3 4; do
  echo "INFO: Approving chaincode for Org${org_num}MSP..."
  # Note: ORDERER_CA_CLI is an env var in the CLI container, accessed as \${ORDERER_CA_CLI}
  APPROVE_CMD="peer lifecycle chaincode approveformyorg \
    -o ${ORDERER_ADDRESS} \
    --ordererTLSHostnameOverride orderer.medtrace.com \
    --channelID ${CHANNEL_NAME} \
    --name ${CC_NAME} \
    --version ${CC_VERSION} \
    --package-id '${CC_PACKAGE_ID}' \
    --sequence ${CC_SEQUENCE} \
    --tls --cafile \"\${ORDERER_CA_CLI}\""

  if [ -n "${INIT_FCN_ARGS}" ]; then
    APPROVE_CMD="${APPROVE_CMD} --init-required"
  fi
  # To specify an endorsement policy, add:
  # --signature-policy "OR('Org1MSP.member', 'Org2MSP.member')"
  # or --channel-config-policy /Channel/Application/Endorsement

  execCliAsOrg "${org_num}" "${APPROVE_CMD}"
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to approve chaincode for Org${org_num}MSP." >&2
    exit 1
  fi

  echo "INFO: Verifying commit readiness for Org${org_num}MSP (informational)..."
  CHECK_COMMIT_CMD="peer lifecycle chaincode checkcommitreadiness \
    --channelID ${CHANNEL_NAME} \
    --name ${CC_NAME} \
    --version ${CC_VERSION} \
    --sequence ${CC_SEQUENCE} \
    --tls --cafile \"\${ORDERER_CA_CLI}\" \
    --output json"
  if [ -n "${INIT_FCN_ARGS}" ]; then
    CHECK_COMMIT_CMD="${CHECK_COMMIT_CMD} --init-required"
  fi
  execCliAsOrg "${org_num}" "${CHECK_COMMIT_CMD}" # Output will be shown if VERBOSE=true or if it fails
done
echo "INFO: Chaincode definition approved by all organizations."
echo "-------------------------------------------------------------------"

# Step 4: Commit Chaincode Definition to Channel
echo "INFO: [Step 4] Committing chaincode definition to channel '${CHANNEL_NAME}'..."
# Construct peer connection parameters for all endorsing peers
# For a 4-org network with default majority policy, we need at least 3.
# Targeting all 4 is robust.
PEER_CONN_PARAMS=""
for org_num_commit in 1 2 3 4; do
  peer_port_commit="" # Variable for this loop iteration
  case $org_num_commit in 1) peer_port_commit=7051 ;; 2) peer_port_commit=8051 ;; 3) peer_port_commit=9051 ;; 4) peer_port_commit=10051 ;; esac
  PEER_CONN_PARAMS="${PEER_CONN_PARAMS} --peerAddresses peer0.org${org_num_commit}.medtrace.com:${peer_port_commit} --tlsRootCertFiles /opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org${org_num_commit}.medtrace.com/peers/peer0.org${org_num_commit}.medtrace.com/tls/ca.crt"
done

COMMIT_CMD="peer lifecycle chaincode commit \
  -o ${ORDERER_ADDRESS} \
  --ordererTLSHostnameOverride orderer.medtrace.com \
  --channelID ${CHANNEL_NAME} \
  --name ${CC_NAME} \
  --version ${CC_VERSION} \
  --sequence ${CC_SEQUENCE} \
  ${PEER_CONN_PARAMS} \
  --tls --cafile \"\${ORDERER_CA_CLI}\""

if [ -n "${INIT_FCN_ARGS}" ]; then
  COMMIT_CMD="${COMMIT_CMD} --init-required"
fi

# Commit can be done as any org that has approved and is part of the channel. Using Org1.
execCliAsOrg "1" "${COMMIT_CMD}"
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to commit chaincode definition." >&2
  exit 1
fi

echo "INFO: Chaincode definition committed successfully."
echo "INFO: Verifying committed chaincode on channel (as Org1)..."
QUERY_COMMITTED_CMD="peer lifecycle chaincode querycommitted --channelID ${CHANNEL_NAME} --name ${CC_NAME} --cafile \"\${ORDERER_CA_CLI}\""
execCliAsOrg "1" "${QUERY_COMMITTED_CMD}"
echo "-------------------------------------------------------------------"

# Step 5: Initialize Chaincode (if --init-required was used and INIT_FCN_ARGS provided)
if [ -n "${INIT_FCN_ARGS}" ]; then
  echo "INFO: [Step 5] Initializing chaincode '${CC_NAME}' on channel '${CHANNEL_NAME}'..."
  # Ensure INIT_FCN_ARGS is properly quoted for the shell command passed to docker exec.
  # The user provides it as '{"Args":["Func"]}', which is a single argument to -cci.
  # When passed to -c in peer chaincode invoke, it should be '{"Args":["Func"]}'.
  INIT_CMD="peer chaincode invoke \
    -o ${ORDERER_ADDRESS} \
    --ordererTLSHostnameOverride orderer.medtrace.com \
    --channelID ${CHANNEL_NAME} \
    --name ${CC_NAME} \
    ${PEER_CONN_PARAMS} \
    --tls --cafile \"\${ORDERER_CA_CLI}\" \
    --isInit \
    -c '${INIT_FCN_ARGS}'" # INIT_FCN_ARGS is already a JSON string

  # Initialize as Org1 (or any org that can invoke)
  execCliAsOrg "1" "${INIT_CMD}"
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to initialize chaincode. The transaction may have failed." >&2
    # Depending on the chaincode, an init failure might be acceptable or critical.
    # For now, exiting on failure.
    exit 1
  fi
  echo "INFO: Chaincode initialization transaction submitted."
else
  echo "INFO: [Step 5] Skipping chaincode initialization as no initialization arguments were provided (-cci flag)."
fi
echo "-------------------------------------------------------------------"

echo "SUCCESS: Chaincode '${CC_NAME}' (Version: ${CC_VERSION}, Sequence: ${CC_SEQUENCE}) deployed successfully to channel '${CHANNEL_NAME}'."
echo "You can now invoke and query the chaincode using the peer CLI or an SDK."
echo
echo "Example query (as Org1, replace YourQueryFunction and args):"
echo "  docker exec ${CLI_CONTAINER_NAME} bash -c ' \\
    export CORE_PEER_LOCALMSPID=\"Org1MSP\"; \\
    export CORE_PEER_TLS_ROOTCERT_FILE=\"/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org1.medtrace.com/peers/peer0.org1.medtrace.com/tls/ca.crt\"; \\
    export CORE_PEER_MSPCONFIGPATH=\"/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org1.medtrace.com/users/Admin@org1.medtrace.com/msp\"; \\
    export CORE_PEER_ADDRESS=\"peer0.org1.medtrace.com:7051\"; \\
    peer chaincode query -C ${CHANNEL_NAME} -n ${CC_NAME} -c \"{\\\"Args\\\":[\\\"YourQueryFunction\\\",\\\"arg1\\\"]}\"'"
echo
echo "Example invoke (as Org1, replace YourInvokeFunction and args):"
echo "  docker exec ${CLI_CONTAINER_NAME} bash -c ' \\
    export CORE_PEER_LOCALMSPID=\"Org1MSP\"; \\
    export CORE_PEER_TLS_ROOTCERT_FILE=\"/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org1.medtrace.com/peers/peer0.org1.medtrace.com/tls/ca.crt\"; \\
    export CORE_PEER_MSPCONFIGPATH=\"/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org1.medtrace.com/users/Admin@org1.medtrace.com/msp\"; \\
    export CORE_PEER_ADDRESS=\"peer0.org1.medtrace.com:7051\"; \\
    peer chaincode invoke -o ${ORDERER_ADDRESS} --ordererTLSHostnameOverride orderer.medtrace.com --tls --cafile \"\${ORDERER_CA_CLI}\" \\
    -C ${CHANNEL_NAME} -n ${CC_NAME} \\
    --peerAddresses peer0.org1.medtrace.com:7051 --tlsRootCertFiles /opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org1.medtrace.com/peers/peer0.org1.medtrace.com/tls/ca.crt \\
    --peerAddresses peer0.org2.medtrace.com:8051 --tlsRootCertFiles /opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org2.medtrace.com/peers/peer0.org2.medtrace.com/tls/ca.crt \\
    -c \"{\\\"Args\\\":[\\\"YourInvokeFunction\\\",\\\"arg1\\\",\\\"arg2\\\"]}\"'"

exit 0

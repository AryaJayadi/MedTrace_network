#!/bin/bash
#
# This script sets up a Hyperledger Fabric network for the MedTrace application.
# It creates 4 organizations, an orderer, and a channel named 'medtrace'.
# Cryptographic material is generated using 'cryptogen'.
#

# Default values
export FABRIC_IMAGE_TAG="latest" # Use "2.5" or other specific version if needed
export CA_IMAGE_TAG="latest"     # Use "1.5" or other specific version if needed
export CHANNEL_NAME="medtrace"
export COMPOSE_PROJECT_NAME="medtrace" # Used by docker-compose to prefix container names

# Root directory of this script
ROOTDIR=$(cd "$(dirname "$0")" && pwd)
export PATH=${ROOTDIR}/../bin:${PWD}/../bin:$PATH # If fabric binaries are in ../bin relative to script or PWD

# Set Fabric config path for configtxgen and cryptogen
export FABRIC_CFG_PATH=${PWD}

# Verbose output
VERBOSE=false

# Docker and Docker Compose commands
: ${CONTAINER_CLI:="docker"}
if command -v ${CONTAINER_CLI}-compose >/dev/null 2>&1; then
  : ${CONTAINER_CLI_COMPOSE:="${CONTAINER_CLI}-compose"}
else
  : ${CONTAINER_CLI_COMPOSE:="${CONTAINER_CLI} compose"}
fi

# Source utility functions from local scripts directory
if [ -f "scripts/utils.sh" ]; then
  . scripts/utils.sh
else
  echo "ERROR: scripts/utils.sh not found. Please ensure it exists in the 'scripts' directory."
  exit 1
fi

# Check if utils.sh was sourced correctly by verifying a function from it
if ! command -v infoln &>/dev/null; then
  echo "ERROR: 'infoln' function not found. Failed to source utils.sh correctly."
  echo "Please ensure scripts/utils.sh is a valid Hyperledger Fabric utility script."
  exit 1
fi

# Function to print help
printHelp() {
  echo "Usage: "
  echo "  medtrace_network.sh <Mode>"
  echo "    Modes:"
  echo "      up - Bring up the network: generate crypto, start containers, create and join channel"
  echo "      down - Clear the network: stop containers, remove crypto material and artifacts"
  echo "      restart - Restart the network"
  echo "      generate - Generate crypto material and channel artifacts only"
  echo
  echo "    Flags:"
  echo "      -verbose - Verbose output"
  echo
  echo "  Example: ./medtrace_network.sh up"
  echo "  Example (verbose): ./medtrace_network.sh up -verbose"
}

# Function to clear previous setup
clearPreviousSetup() {
  infoln "Cleaning up previous network..."
  # Stop and remove containers, networks, volumes, and images created by docker-compose
  if [ -f "docker-compose.yaml" ]; then
    ${CONTAINER_CLI_COMPOSE} -p ${COMPOSE_PROJECT_NAME} down --volumes --remove-orphans 2>/dev/null
  fi

  # Remove chaincode containers
  ${CONTAINER_CLI} rm -f $(${CONTAINER_CLI} ps -aq --filter "name=dev-peer*") 2>/dev/null || true

  # Remove generated artifacts
  rm -rf organizations system-genesis-block channel-artifacts
  rm -f crypto-config-*.yaml configtx.yaml docker-compose.yaml
  rm -f log.txt *.tar.gz

  infoln "Previous network cleanup complete."
}

# Check for prerequisites
checkPrereqs() {
  infoln "Checking prerequisites..."
  command -v cryptogen >/dev/null 2>&1 || {
    errorln "cryptogen tool not found. exiting"
    exit 1
  }
  command -v configtxgen >/dev/null 2>&1 || {
    errorln "configtxgen tool not found. exiting"
    exit 1
  }
  command -v ${CONTAINER_CLI} >/dev/null 2>&1 || {
    errorln "${CONTAINER_CLI} not found. exiting"
    exit 1
  }
  command -v ${CONTAINER_CLI_COMPOSE} >/dev/null 2>&1 || {
    errorln "${CONTAINER_CLI_COMPOSE} not found. exiting"
    exit 1
  }
  infoln "Prerequisites checked."
}

# Generate crypto material using cryptogen
generateCryptoMaterial() {
  if [ -d "organizations" ]; then
    infoln "Found existing 'organizations' directory. Using existing crypto material."
    return
  fi
  infoln "Generating crypto material..."

  # Create crypto-config for Org1
  cat <<EOF >crypto-config-org1.yaml
PeerOrgs:
  - Name: Org1
    Domain: org1.medtrace.com
    EnableNodeOUs: true
    Template:
      Count: 1
    Users:
      Count: 1
EOF
  cryptogen generate --config=./crypto-config-org1.yaml --output="organizations"
  if [ $? -ne 0 ]; then fatalln "Failed to generate crypto material for Org1"; fi

  # Create crypto-config for Org2
  cat <<EOF >crypto-config-org2.yaml
PeerOrgs:
  - Name: Org2
    Domain: org2.medtrace.com
    EnableNodeOUs: true
    Template:
      Count: 1
    Users:
      Count: 1
EOF
  cryptogen generate --config=./crypto-config-org2.yaml --output="organizations"
  if [ $? -ne 0 ]; then fatalln "Failed to generate crypto material for Org2"; fi

  # Create crypto-config for Org3
  cat <<EOF >crypto-config-org3.yaml
PeerOrgs:
  - Name: Org3
    Domain: org3.medtrace.com
    EnableNodeOUs: true
    Template:
      Count: 1
    Users:
      Count: 1
EOF
  cryptogen generate --config=./crypto-config-org3.yaml --output="organizations"
  if [ $? -ne 0 ]; then fatalln "Failed to generate crypto material for Org3"; fi

  # Create crypto-config for Org4
  cat <<EOF >crypto-config-org4.yaml
PeerOrgs:
  - Name: Org4
    Domain: org4.medtrace.com
    EnableNodeOUs: true
    Template:
      Count: 1
    Users:
      Count: 1
EOF
  cryptogen generate --config=./crypto-config-org4.yaml --output="organizations"
  if [ $? -ne 0 ]; then fatalln "Failed to generate crypto material for Org4"; fi

  # Create crypto-config for Orderer Org
  cat <<EOF >crypto-config-orderer.yaml
OrdererOrgs:
  - Name: Orderer
    Domain: medtrace.com
    EnableNodeOUs: true
    Specs:
      - Hostname: orderer # This will be orderer.medtrace.com
EOF
  cryptogen generate --config=./crypto-config-orderer.yaml --output="organizations"
  if [ $? -ne 0 ]; then fatalln "Failed to generate crypto material for Orderer"; fi

  infoln "Crypto material generated successfully."
}

# Generate channel artifacts using configtxgen
generateChannelArtifacts() {
  if [ -f "channel-artifacts/${CHANNEL_NAME}.tx" ] && [ -f "system-genesis-block/genesis.block" ]; then
    infoln "Found existing channel artifacts. Using existing artifacts."
    return
  fi
  infoln "Generating channel artifacts..."

  # Create configtx.yaml
  cat <<EOF >configtx.yaml
Organizations:
    - &OrdererOrg
        Name: OrdererMSP
        ID: OrdererMSP
        MSPDir: organizations/ordererOrganizations/medtrace.com/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('OrdererMSP.member')"
            Writers:
                Type: Signature
                Rule: "OR('OrdererMSP.member')"
            Admins:
                Type: Signature
                Rule: "OR('OrdererMSP.admin')"
        OrdererEndpoints: # Required for service discovery
            - "orderer.medtrace.com:7050"
    - &Org1
        Name: Org1MSP
        ID: Org1MSP
        MSPDir: organizations/peerOrganizations/org1.medtrace.com/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('Org1MSP.admin', 'Org1MSP.peer', 'Org1MSP.client')"
            Writers:
                Type: Signature
                Rule: "OR('Org1MSP.admin', 'Org1MSP.client')"
            Admins:
                Type: Signature
                Rule: "OR('Org1MSP.admin')"
            Endorsement:
                Type: Signature
                Rule: "OR('Org1MSP.peer')"
        AnchorPeers:
            - Host: peer0.org1.medtrace.com
              Port: 7051
    - &Org2
        Name: Org2MSP
        ID: Org2MSP
        MSPDir: organizations/peerOrganizations/org2.medtrace.com/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('Org2MSP.admin', 'Org2MSP.peer', 'Org2MSP.client')"
            Writers:
                Type: Signature
                Rule: "OR('Org2MSP.admin', 'Org2MSP.client')"
            Admins:
                Type: Signature
                Rule: "OR('Org2MSP.admin')"
            Endorsement:
                Type: Signature
                Rule: "OR('Org2MSP.peer')"
        AnchorPeers:
            - Host: peer0.org2.medtrace.com
              Port: 8051
    - &Org3
        Name: Org3MSP
        ID: Org3MSP
        MSPDir: organizations/peerOrganizations/org3.medtrace.com/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('Org3MSP.admin', 'Org3MSP.peer', 'Org3MSP.client')"
            Writers:
                Type: Signature
                Rule: "OR('Org3MSP.admin', 'Org3MSP.client')"
            Admins:
                Type: Signature
                Rule: "OR('Org3MSP.admin')"
            Endorsement:
                Type: Signature
                Rule: "OR('Org3MSP.peer')"
        AnchorPeers:
            - Host: peer0.org3.medtrace.com
              Port: 9051
    - &Org4
        Name: Org4MSP
        ID: Org4MSP
        MSPDir: organizations/peerOrganizations/org4.medtrace.com/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('Org4MSP.admin', 'Org4MSP.peer', 'Org4MSP.client')"
            Writers:
                Type: Signature
                Rule: "OR('Org4MSP.admin', 'Org4MSP.client')"
            Admins:
                Type: Signature
                Rule: "OR('Org4MSP.admin')"
            Endorsement:
                Type: Signature
                Rule: "OR('Org4MSP.peer')"
        AnchorPeers:
            - Host: peer0.org4.medtrace.com
              Port: 10051

Capabilities:
    Channel: &ChannelCapabilities
        V2_0: true
    Orderer: &OrdererCapabilities
        V2_0: true
    Application: &ApplicationCapabilities
        V2_5: true # Or V2_0 if using Fabric < 2.5

Application: &ApplicationDefaults
    Organizations:
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
        LifecycleEndorsement:
            Type: ImplicitMeta
            Rule: "MAJORITY Endorsement" # Default policy for chaincode lifecycle
        Endorsement:
            Type: ImplicitMeta
            Rule: "MAJORITY Endorsement" # Default policy for chaincode endorsement
    Capabilities:
        <<: *ApplicationCapabilities

Orderer: &OrdererDefaults
    OrdererType: etcdraft
    EtcdRaft:
        Consenters:
            - Host: orderer.medtrace.com
              Port: 7050
              ClientTLSCert: organizations/ordererOrganizations/medtrace.com/orderers/orderer.medtrace.com/tls/server.crt
              ServerTLSCert: organizations/ordererOrganizations/medtrace.com/orderers/orderer.medtrace.com/tls/server.crt
    Addresses:
        - orderer.medtrace.com:7050
    BatchTimeout: 2s
    BatchSize:
        MaxMessageCount: 10
        AbsoluteMaxBytes: 99 MB
        PreferredMaxBytes: 512 KB
    Organizations:
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
        BlockValidation: # Implicitly defined by SystemChannel Consortium
            Type: ImplicitMeta
            Rule: "ANY Writers"

Channel: &ChannelDefaults
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
    Capabilities:
        <<: *ChannelCapabilities

Profiles:
    FourOrgsOrdererGenesis:
        <<: *ChannelDefaults
        Orderer:
            <<: *OrdererDefaults
            Organizations:
                - *OrdererOrg
            Capabilities:
                <<: *OrdererCapabilities
        Consortiums:
            MedTraceConsortium:
                Organizations:
                    - *Org1
                    - *Org2
                    - *Org3
                    - *Org4
    FourOrgsChannel:
        Consortium: MedTraceConsortium
        <<: *ChannelDefaults
        Application:
            <<: *ApplicationDefaults
            Organizations:
                - *Org1
                - *Org2
                - *Org3
                - *Org4
            Capabilities:
                <<: *ApplicationCapabilities
EOF

  mkdir -p system-genesis-block channel-artifacts

  infoln "Generating Orderer Genesis block"
  configtxgen -profile FourOrgsOrdererGenesis -channelID system-channel -outputBlock ./system-genesis-block/genesis.block
  if [ $? -ne 0 ]; then fatalln "Failed to generate orderer genesis block"; fi

  infoln "Generating Channel Creation Transaction for channel ${CHANNEL_NAME}"
  configtxgen -profile FourOrgsChannel -outputCreateChannelTx ./channel-artifacts/${CHANNEL_NAME}.tx -channelID $CHANNEL_NAME
  if [ $? -ne 0 ]; then fatalln "Failed to generate channel creation transaction for ${CHANNEL_NAME}"; fi

  infoln "Generating Anchor Peer Updates for channel ${CHANNEL_NAME}"
  configtxgen -profile FourOrgsChannel -outputAnchorPeersUpdate ./channel-artifacts/Org1MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Org1MSP
  if [ $? -ne 0 ]; then fatalln "Failed to generate anchor peer update for Org1MSP"; fi
  configtxgen -profile FourOrgsChannel -outputAnchorPeersUpdate ./channel-artifacts/Org2MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Org2MSP
  if [ $? -ne 0 ]; then fatalln "Failed to generate anchor peer update for Org2MSP"; fi
  configtxgen -profile FourOrgsChannel -outputAnchorPeersUpdate ./channel-artifacts/Org3MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Org3MSP
  if [ $? -ne 0 ]; then fatalln "Failed to generate anchor peer update for Org3MSP"; fi
  configtxgen -profile FourOrgsChannel -outputAnchorPeersUpdate ./channel-artifacts/Org4MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Org4MSP
  if [ $? -ne 0 ]; then fatalln "Failed to generate anchor peer update for Org4MSP"; fi

  infoln "Channel artifacts generated successfully."
}

# Start the network
startNetwork() {
  # Check if already up
  if [ "$(${CONTAINER_CLI} ps -q -f name=orderer.medtrace.com)" ]; then
    infoln "Network containers are already running."
    return
  fi

  infoln "Starting network containers..."
  # Create docker-compose.yaml
  cat <<EOF >docker-compose.yaml
# version: '3.7' # Obsolete, remove for Docker Compose V2 compatibility

volumes:
  orderer.medtrace.com:
  peer0.org1.medtrace.com:
  peer0.org2.medtrace.com:
  peer0.org3.medtrace.com:
  peer0.org4.medtrace.com:

networks:
  medtrace_network:
    name: fabric_medtrace
    driver: bridge

services:
  orderer.medtrace.com:
    container_name: orderer.medtrace.com
    image: hyperledger/fabric-orderer:${FABRIC_IMAGE_TAG}
    environment:
      - FABRIC_LOGGING_SPEC=INFO # Can be set to DEBUG for more orderer logs
      - ORDERER_GENERAL_LISTENADDRESS=0.0.0.0
      - ORDERER_GENERAL_LISTENPORT=7050
      - ORDERER_GENERAL_LOCALMSPID=OrdererMSP
      - ORDERER_GENERAL_LOCALMSPDIR=/var/hyperledger/orderer/msp
      - ORDERER_GENERAL_TLS_ENABLED=true
      - ORDERER_GENERAL_TLS_PRIVATEKEY=/var/hyperledger/orderer/tls/server.key
      - ORDERER_GENERAL_TLS_CERTIFICATE=/var/hyperledger/orderer/tls/server.crt
      - ORDERER_GENERAL_TLS_ROOTCAS=[/var/hyperledger/orderer/tls/ca.crt]
      - ORDERER_GENERAL_GENESISMETHOD=file
      - ORDERER_GENERAL_GENESISFILE=/var/hyperledger/orderer/orderer.genesis.block
      - ORDERER_GENERAL_CLUSTER_CLIENTCERTIFICATE=/var/hyperledger/orderer/tls/server.crt
      - ORDERER_GENERAL_CLUSTER_CLIENTPRIVATEKEY=/var/hyperledger/orderer/tls/server.key
      - ORDERER_GENERAL_CLUSTER_ROOTCAS=[/var/hyperledger/orderer/tls/ca.crt]
      - ORDERER_ADMIN_TLS_ENABLED=true
      - ORDERER_ADMIN_TLS_CERTIFICATE=/var/hyperledger/orderer/tls/server.crt
      - ORDERER_ADMIN_TLS_PRIVATEKEY=/var/hyperledger/orderer/tls/server.key
      - ORDERER_ADMIN_TLS_ROOTCAS=[/var/hyperledger/orderer/tls/ca.crt] 
      - ORDERER_ADMIN_LISTENADDRESS=0.0.0.0:7053 
      - ORDERER_OPERATIONS_LISTENADDRESS=0.0.0.0:9443 
      - ORDERER_METRICS_PROVIDER=prometheus
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric
    command: orderer
    volumes:
      - ./system-genesis-block/genesis.block:/var/hyperledger/orderer/orderer.genesis.block
      - ./organizations/ordererOrganizations/medtrace.com/orderers/orderer.medtrace.com/msp:/var/hyperledger/orderer/msp
      - ./organizations/ordererOrganizations/medtrace.com/orderers/orderer.medtrace.com/tls:/var/hyperledger/orderer/tls
      - orderer.medtrace.com:/var/hyperledger/production/orderer
    ports:
      - "7050:7050" 
      - "7053:7053" 
      - "9443:9443" 
    networks:
      - medtrace_network

  peer0.org1.medtrace.com:
    container_name: peer0.org1.medtrace.com
    image: hyperledger/fabric-peer:${FABRIC_IMAGE_TAG}
    environment:
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=fabric_medtrace 
      - FABRIC_LOGGING_SPEC=INFO # Can be set to DEBUG for more peer logs
      - CORE_PEER_TLS_ENABLED=true
      - CORE_PEER_PROFILE_ENABLED=false 
      - CORE_PEER_TLS_CERT_FILE=/etc/hyperledger/fabric/tls/server.crt
      - CORE_PEER_TLS_KEY_FILE=/etc/hyperledger/fabric/tls/server.key
      - CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/tls/ca.crt
      - CORE_PEER_ID=peer0.org1.medtrace.com
      - CORE_PEER_ADDRESS=peer0.org1.medtrace.com:7051
      - CORE_PEER_LISTENADDRESS=0.0.0.0:7051
      - CORE_PEER_CHAINCODEADDRESS=peer0.org1.medtrace.com:7052 
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:7052
      - CORE_PEER_GOSSIP_BOOTSTRAP=peer0.org1.medtrace.com:7051
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=peer0.org1.medtrace.com:7051
      - CORE_PEER_LOCALMSPID=Org1MSP
      - CORE_OPERATIONS_LISTENADDRESS=0.0.0.0:9444 
      - CORE_METRICS_PROVIDER=prometheus 
    volumes:
      - /var/run/:/host/var/run/
      - ./organizations/peerOrganizations/org1.medtrace.com/peers/peer0.org1.medtrace.com/msp:/etc/hyperledger/fabric/msp
      - ./organizations/peerOrganizations/org1.medtrace.com/peers/peer0.org1.medtrace.com/tls:/etc/hyperledger/fabric/tls
      - peer0.org1.medtrace.com:/var/hyperledger/production
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: peer node start
    ports:
      - "7051:7051"
      - "9444:9444" 
    networks:
      - medtrace_network

  peer0.org2.medtrace.com:
    container_name: peer0.org2.medtrace.com
    image: hyperledger/fabric-peer:${FABRIC_IMAGE_TAG}
    environment:
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=fabric_medtrace
      - FABRIC_LOGGING_SPEC=INFO
      - CORE_PEER_TLS_ENABLED=true
      - CORE_PEER_PROFILE_ENABLED=false
      - CORE_PEER_TLS_CERT_FILE=/etc/hyperledger/fabric/tls/server.crt
      - CORE_PEER_TLS_KEY_FILE=/etc/hyperledger/fabric/tls/server.key
      - CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/tls/ca.crt
      - CORE_PEER_ID=peer0.org2.medtrace.com
      - CORE_PEER_ADDRESS=peer0.org2.medtrace.com:8051
      - CORE_PEER_LISTENADDRESS=0.0.0.0:8051
      - CORE_PEER_CHAINCODEADDRESS=peer0.org2.medtrace.com:8052
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:8052
      - CORE_PEER_GOSSIP_BOOTSTRAP=peer0.org2.medtrace.com:8051
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=peer0.org2.medtrace.com:8051
      - CORE_PEER_LOCALMSPID=Org2MSP
      - CORE_OPERATIONS_LISTENADDRESS=0.0.0.0:9445
      - CORE_METRICS_PROVIDER=prometheus
    volumes:
      - /var/run/:/host/var/run/
      - ./organizations/peerOrganizations/org2.medtrace.com/peers/peer0.org2.medtrace.com/msp:/etc/hyperledger/fabric/msp
      - ./organizations/peerOrganizations/org2.medtrace.com/peers/peer0.org2.medtrace.com/tls:/etc/hyperledger/fabric/tls
      - peer0.org2.medtrace.com:/var/hyperledger/production
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: peer node start
    ports:
      - "8051:8051"
      - "9445:9445"
    networks:
      - medtrace_network

  peer0.org3.medtrace.com:
    container_name: peer0.org3.medtrace.com
    image: hyperledger/fabric-peer:${FABRIC_IMAGE_TAG}
    environment:
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=fabric_medtrace
      - FABRIC_LOGGING_SPEC=INFO
      - CORE_PEER_TLS_ENABLED=true
      - CORE_PEER_PROFILE_ENABLED=false
      - CORE_PEER_TLS_CERT_FILE=/etc/hyperledger/fabric/tls/server.crt
      - CORE_PEER_TLS_KEY_FILE=/etc/hyperledger/fabric/tls/server.key
      - CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/tls/ca.crt
      - CORE_PEER_ID=peer0.org3.medtrace.com
      - CORE_PEER_ADDRESS=peer0.org3.medtrace.com:9051
      - CORE_PEER_LISTENADDRESS=0.0.0.0:9051
      - CORE_PEER_CHAINCODEADDRESS=peer0.org3.medtrace.com:9052
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:9052
      - CORE_PEER_GOSSIP_BOOTSTRAP=peer0.org3.medtrace.com:9051
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=peer0.org3.medtrace.com:9051
      - CORE_PEER_LOCALMSPID=Org3MSP
      - CORE_OPERATIONS_LISTENADDRESS=0.0.0.0:9446
      - CORE_METRICS_PROVIDER=prometheus
    volumes:
      - /var/run/:/host/var/run/
      - ./organizations/peerOrganizations/org3.medtrace.com/peers/peer0.org3.medtrace.com/msp:/etc/hyperledger/fabric/msp
      - ./organizations/peerOrganizations/org3.medtrace.com/peers/peer0.org3.medtrace.com/tls:/etc/hyperledger/fabric/tls
      - peer0.org3.medtrace.com:/var/hyperledger/production
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: peer node start
    ports:
      - "9051:9051"
      - "9446:9446"
    networks:
      - medtrace_network

  peer0.org4.medtrace.com:
    container_name: peer0.org4.medtrace.com
    image: hyperledger/fabric-peer:${FABRIC_IMAGE_TAG}
    environment:
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=fabric_medtrace
      - FABRIC_LOGGING_SPEC=INFO
      - CORE_PEER_TLS_ENABLED=true
      - CORE_PEER_PROFILE_ENABLED=false
      - CORE_PEER_TLS_CERT_FILE=/etc/hyperledger/fabric/tls/server.crt
      - CORE_PEER_TLS_KEY_FILE=/etc/hyperledger/fabric/tls/server.key
      - CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/tls/ca.crt
      - CORE_PEER_ID=peer0.org4.medtrace.com
      - CORE_PEER_ADDRESS=peer0.org4.medtrace.com:10051
      - CORE_PEER_LISTENADDRESS=0.0.0.0:10051
      - CORE_PEER_CHAINCODEADDRESS=peer0.org4.medtrace.com:10052
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:10052
      - CORE_PEER_GOSSIP_BOOTSTRAP=peer0.org4.medtrace.com:10051
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=peer0.org4.medtrace.com:10051
      - CORE_PEER_LOCALMSPID=Org4MSP
      - CORE_OPERATIONS_LISTENADDRESS=0.0.0.0:9447
      - CORE_METRICS_PROVIDER=prometheus
    volumes:
      - /var/run/:/host/var/run/
      - ./organizations/peerOrganizations/org4.medtrace.com/peers/peer0.org4.medtrace.com/msp:/etc/hyperledger/fabric/msp
      - ./organizations/peerOrganizations/org4.medtrace.com/peers/peer0.org4.medtrace.com/tls:/etc/hyperledger/fabric/tls
      - peer0.org4.medtrace.com:/var/hyperledger/production
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: peer node start
    ports:
      - "10051:10051"
      - "9447:9447"
    networks:
      - medtrace_network

  cli:
    container_name: cli.medtrace.com
    image: hyperledger/fabric-tools:${FABRIC_IMAGE_TAG}
    tty: true
    stdin_open: true
    environment:
      - GOPATH=/opt/gopath
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - FABRIC_LOGGING_SPEC=INFO # CLI logging, can be DEBUG for peer commands
      - CORE_PEER_ID=cli 
      - CORE_PEER_ADDRESS=peer0.org1.medtrace.com:7051 
      - CORE_PEER_LOCALMSPID=Org1MSP 
      - CORE_PEER_TLS_ENABLED=true
      - CORE_PEER_TLS_ROOTCERT_FILE=/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org1.medtrace.com/peers/peer0.org1.medtrace.com/tls/ca.crt
      - CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/org1.medtrace.com/users/Admin@org1.medtrace.com/msp
      - ORDERER_CA_CLI=/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/ordererOrganizations/medtrace.com/orderers/orderer.medtrace.com/tls/ca.crt
      - ORDERER_ADMIN_TLS_SIGN_CERT=/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/ordererOrganizations/medtrace.com/users/Admin@medtrace.com/tls/signcerts/cert.pem 
      - ORDERER_ADMIN_TLS_PRIVATE_KEY=/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/ordererOrganizations/medtrace.com/users/Admin@medtrace.com/tls/keystore/key.pem 
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: /bin/bash
    volumes:
      - /var/run/:/host/var/run/
      - ./organizations:/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations
      - ./channel-artifacts:/opt/gopath/src/github.com/hyperledger/fabric/peer/channel-artifacts
      - ./system-genesis-block:/opt/gopath/src/github.com/hyperledger/fabric/peer/system-genesis-block
      # Mount local scripts directory to CLI container
      - ./scripts:/opt/gopath/src/github.com/hyperledger/fabric/peer/scripts 
    depends_on:
      - orderer.medtrace.com
      - peer0.org1.medtrace.com
      - peer0.org2.medtrace.com
      - peer0.org3.medtrace.com
      - peer0.org4.medtrace.com
    networks:
      - medtrace_network
EOF

  ${CONTAINER_CLI_COMPOSE} -p ${COMPOSE_PROJECT_NAME} -f docker-compose.yaml up -d 2>&1

  ${CONTAINER_CLI} ps -a
  if [ $? -ne 0 ]; then
    fatalln "Unable to start network"
  fi

  infoln "Waiting a few seconds for network services to initialize..."
  sleep 10

  # Enhanced Wait for orderer to be up and responsive
  infoln "Waiting for orderer (orderer.medtrace.com:7050) to be ready..."
  local COUNT=0
  local MAX_RETRY_LOGS=20
  local MAX_RETRY_CONNECT=20
  local ORDERER_LOG_READY=false
  local ORDERER_CONNECT_READY=false # Renamed from DNS_RESOLVED for clarity

  # Check logs first
  while [ $COUNT -lt $MAX_RETRY_LOGS ]; do
    if ${CONTAINER_CLI} logs orderer.medtrace.com 2>&1 | grep -q "Start accepting requests as Raft leader"; then
      ORDERER_LOG_READY=true
      infoln "Orderer log indicates 'Start accepting requests as Raft leader'."
      break
    elif ${CONTAINER_CLI} logs orderer.medtrace.com 2>&1 | grep -q "Beginning to serve requests"; then
      ORDERER_LOG_READY=true
      infoln "Orderer log indicates 'Beginning to serve requests'."
      break
    fi
    sleep 3
    COUNT=$((COUNT + 1))
    if [ "$VERBOSE" == "true" ]; then
      infoln "Still waiting for orderer logs... attempt $COUNT/$MAX_RETRY_LOGS"
    fi
  done

  if [ "$ORDERER_LOG_READY" = "false" ]; then
    errorln "Orderer (orderer.medtrace.com) log did not show readiness message after $MAX_RETRY_LOGS retries."
    ${CONTAINER_CLI} logs orderer.medtrace.com
    fatalln "Orderer not ready based on log check."
  fi

  infoln "Verifying DNS resolution and connectivity to orderer.medtrace.com:7050 from CLI..."
  COUNT=0
  while [ $COUNT -lt $MAX_RETRY_CONNECT ]; do
    local DNS_LOOKUP_SUCCESSFUL=false
    if [ "$VERBOSE" == "true" ]; then
      infoln "--- DNS Diagnostics (Attempt $((COUNT + 1))/$MAX_RETRY_CONNECT) ---"
      infoln "CLI /etc/resolv.conf:"
      ${CONTAINER_CLI} exec cli.medtrace.com cat /etc/resolv.conf || true
      infoln "CLI nslookup orderer.medtrace.com:"
      ${CONTAINER_CLI} exec cli.medtrace.com nslookup orderer.medtrace.com || infoln "nslookup command failed or not found."
      infoln "CLI getent hosts orderer.medtrace.com:"
      GETENT_OUTPUT=$(${CONTAINER_CLI} exec cli.medtrace.com getent hosts orderer.medtrace.com)
      if [ $? -eq 0 ] && [ -n "$GETENT_OUTPUT" ]; then
        infoln "$GETENT_OUTPUT"
        DNS_LOOKUP_SUCCESSFUL=true
      else
        infoln "getent hosts orderer.medtrace.com failed or returned empty."
        DNS_LOOKUP_SUCCESSFUL=false
      fi
      infoln "--- End DNS Diagnostics ---"
    else
      # Silent check for non-verbose mode
      if ${CONTAINER_CLI} exec cli.medtrace.com getent hosts orderer.medtrace.com >/dev/null 2>&1; then
        DNS_LOOKUP_SUCCESSFUL=true
      fi
    fi

    if [ "$DNS_LOOKUP_SUCCESSFUL" == "true" ]; then
      if [ "$VERBOSE" == "true" ]; then
        infoln "DNS resolution for orderer.medtrace.com appears successful."
        # The problematic 'peer version' command is removed.
        # The actual channel create command will test full connectivity.
      fi
      ORDERER_CONNECT_READY=true # Consider DNS resolution as sufficient pre-check
      break
    else
      if [ "$VERBOSE" == "true" ]; then
        infoln "DNS resolution for orderer.medtrace.com failed. Retrying..."
      fi
    fi
    sleep 5
    COUNT=$((COUNT + 1))
  done

  if [ "$ORDERER_CONNECT_READY" = "false" ]; then
    errorln "Failed to resolve DNS for orderer (orderer.medtrace.com) from CLI after $MAX_RETRY_CONNECT retries."
    fatalln "Orderer DNS resolution failed. Check verbose output if enabled. Ensure Docker networking and DNS are functioning correctly."
  fi

  infoln "Network containers started. Orderer log indicates readiness and DNS resolution from CLI is successful."
}

# Create and join channel
createAndJoinChannel() {
  infoln "Creating channel ${CHANNEL_NAME}..."

  local ORDERER_CA_CLI="/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/ordererOrganizations/medtrace.com/orderers/orderer.medtrace.com/tls/ca.crt"
  local ORDERER_ADDRESS="orderer.medtrace.com:7050"

  # Default CLI context is Org1 admin
  # Add retry logic for channel creation as it might still fail due to timing
  local CHANNEL_CREATE_ATTEMPTS=0
  local MAX_CHANNEL_CREATE_ATTEMPTS=3
  local CHANNEL_CREATED=false
  while [ $CHANNEL_CREATE_ATTEMPTS -lt $MAX_CHANNEL_CREATE_ATTEMPTS ]; do
    infoln "Attempting to create channel ${CHANNEL_NAME} (Attempt $((CHANNEL_CREATE_ATTEMPTS + 1))/$MAX_CHANNEL_CREATE_ATTEMPTS)..."
    COMMAND_OUTPUT=$(${CONTAINER_CLI} exec cli.medtrace.com peer channel create \
      -o ${ORDERER_ADDRESS} \
      -c ${CHANNEL_NAME} \
      --ordererTLSHostnameOverride orderer.medtrace.com \
      -f ./channel-artifacts/${CHANNEL_NAME}.tx \
      --outputBlock ./channel-artifacts/${CHANNEL_NAME}.block \
      --tls --cafile ${ORDERER_CA_CLI} 2>&1)
    COMMAND_EXIT_CODE=$?

    if [ "$VERBOSE" == "true" ]; then
      infoln "peer channel create output:"
      echo "${COMMAND_OUTPUT}"
      infoln "peer channel create exit code: ${COMMAND_EXIT_CODE}"
    fi

    if [ ${COMMAND_EXIT_CODE} -eq 0 ]; then
      CHANNEL_CREATED=true
      break
    else
      errorln "Failed to create channel ${CHANNEL_NAME} on attempt $((CHANNEL_CREATE_ATTEMPTS + 1)). Retrying in 10 seconds..."
      sleep 10
    fi
    CHANNEL_CREATE_ATTEMPTS=$((CHANNEL_CREATE_ATTEMPTS + 1))
  done

  if [ "$CHANNEL_CREATED" != "true" ]; then
    fatalln "Failed to create channel ${CHANNEL_NAME} after $MAX_CHANNEL_CREATE_ATTEMPTS attempts."
  fi

  infoln "Channel ${CHANNEL_NAME} created successfully. Block: channel-artifacts/${CHANNEL_NAME}.block"

  for ORG_NUM in 1 2 3 4; do
    local ORG_DOMAIN="org${ORG_NUM}.medtrace.com"
    local MSP_ID="Org${ORG_NUM}MSP"
    local PEER_HOST="peer0.${ORG_DOMAIN}"
    local PEER_PORT
    case $ORG_NUM in
    1) PEER_PORT=7051 ;;
    2) PEER_PORT=8051 ;;
    3) PEER_PORT=9051 ;;
    4) PEER_PORT=10051 ;;
    esac
    local PEER_ADDRESS_FULL="${PEER_HOST}:${PEER_PORT}"

    infoln "Joining ${PEER_HOST} to channel ${CHANNEL_NAME}..."

    local CORE_PEER_MSPCONFIGPATH_ORG="/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/${ORG_DOMAIN}/users/Admin@${ORG_DOMAIN}/msp"
    local CORE_PEER_TLS_ROOTCERT_FILE_ORG="/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/${ORG_DOMAIN}/peers/${PEER_HOST}/tls/ca.crt"

    ${CONTAINER_CLI} exec \
      -e "CORE_PEER_LOCALMSPID=${MSP_ID}" \
      -e "CORE_PEER_TLS_ROOTCERT_FILE=${CORE_PEER_TLS_ROOTCERT_FILE_ORG}" \
      -e "CORE_PEER_MSPCONFIGPATH=${CORE_PEER_MSPCONFIGPATH_ORG}" \
      -e "CORE_PEER_ADDRESS=${PEER_ADDRESS_FULL}" \
      cli.medtrace.com peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block --tls --cafile ${ORDERER_CA_CLI}

    if [ $? -ne 0 ]; then fatalln "Failed to join ${PEER_HOST} to channel ${CHANNEL_NAME}"; fi
    infoln "${PEER_HOST} successfully joined channel ${CHANNEL_NAME}."
  done

  for ORG_NUM in 1 2 3 4; do
    local ORG_DOMAIN="org${ORG_NUM}.medtrace.com"
    local MSP_ID="Org${ORG_NUM}MSP"
    local PEER_HOST="peer0.${ORG_DOMAIN}"
    local PEER_PORT
    case $ORG_NUM in
    1) PEER_PORT=7051 ;;
    2) PEER_PORT=8051 ;;
    3) PEER_PORT=9051 ;;
    4) PEER_PORT=10051 ;;
    esac
    local PEER_ADDRESS_FULL="${PEER_HOST}:${PEER_PORT}"

    infoln "Updating anchor peer for ${MSP_ID} on channel ${CHANNEL_NAME} via ${PEER_HOST}..."

    local CORE_PEER_MSPCONFIGPATH_ORG="/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/${ORG_DOMAIN}/users/Admin@${ORG_DOMAIN}/msp"
    local CORE_PEER_TLS_ROOTCERT_FILE_ORG="/opt/gopath/src/github.com/hyperledger/fabric/peer/organizations/peerOrganizations/${ORG_DOMAIN}/peers/${PEER_HOST}/tls/ca.crt"

    ${CONTAINER_CLI} exec \
      -e "CORE_PEER_LOCALMSPID=${MSP_ID}" \
      -e "CORE_PEER_TLS_ROOTCERT_FILE=${CORE_PEER_TLS_ROOTCERT_FILE_ORG}" \
      -e "CORE_PEER_MSPCONFIGPATH=${CORE_PEER_MSPCONFIGPATH_ORG}" \
      -e "CORE_PEER_ADDRESS=${PEER_ADDRESS_FULL}" \
      cli.medtrace.com peer channel update \
      -o ${ORDERER_ADDRESS} \
      --ordererTLSHostnameOverride orderer.medtrace.com \
      -c ${CHANNEL_NAME} \
      -f ./channel-artifacts/${MSP_ID}anchors.tx \
      --tls --cafile ${ORDERER_CA_CLI}

    if [ $? -ne 0 ]; then fatalln "Failed to update anchor peer for ${MSP_ID} on channel ${CHANNEL_NAME}"; fi
    infoln "Anchor peer for ${MSP_ID} on channel ${CHANNEL_NAME} updated successfully."
  done

  infoln "Channel ${CHANNEL_NAME} successfully configured."
}

# Network Down
networkDown() {
  infoln "Stopping and removing network..."
  if [ -f "docker-compose.yaml" ]; then
    ${CONTAINER_CLI_COMPOSE} -p ${COMPOSE_PROJECT_NAME} down --volumes --remove-orphans
  fi
  infoln "Network stopped."

  infoln "Removing generated artifacts..."
  rm -rf organizations system-genesis-block channel-artifacts
  rm -f crypto-config-*.yaml configtx.yaml docker-compose.yaml
  rm -f log.txt *.tar.gz
  infoln "Artifacts removed."
}

# Parse commandline args
if [[ $# -lt 1 ]]; then
  printHelp
  exit 0
else
  MODE=$1
  shift
fi

# Parse flags
while [[ $# -ge 1 ]]; do
  key="$1"
  case $key in
  -verbose)
    VERBOSE=true
    infoln "Verbose mode enabled"
    ;;
  *)
    errorln "Unknown flag: $key"
    printHelp
    exit 1
    ;;
  esac
  shift
done

# Main logic
if [ "$MODE" == "up" ]; then
  checkPrereqs
  generateCryptoMaterial
  generateChannelArtifacts
  startNetwork
  createAndJoinChannel
  successln "MedTrace network is up and channel '${CHANNEL_NAME}' is ready."
elif [ "$MODE" == "down" ]; then
  networkDown
  successln "MedTrace network is down."
elif [ "$MODE" == "restart" ]; then
  networkDown
  checkPrereqs
  generateCryptoMaterial
  generateChannelArtifacts
  startNetwork
  createAndJoinChannel
  successln "MedTrace network restarted and channel '${CHANNEL_NAME}' is ready."
elif [ "$MODE" == "generate" ]; then
  checkPrereqs
  generateCryptoMaterial
  generateChannelArtifacts
  successln "Crypto material and channel artifacts generated."
else
  printHelp
  exit 1
fi

exit 0

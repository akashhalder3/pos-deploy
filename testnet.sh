#!/bin/bash

set -exu
set -o pipefail

# NETWORK_DIR is where all files for the testnet will be stored,
# including logs and storage
NETWORK_DIR=./network

# Change this number for your desired number of nodes
NUM_NODES=64

# Port information. All ports will be incremented upon
# with more validators to prevent port conflicts on a single machine
GETH_BOOTNODE_PORT=30301

GETH_HTTP_PORT=8545
GETH_WS_PORT=8546
GETH_AUTH_RPC_PORT=8547
GETH_METRICS_PORT=8548
GETH_NETWORK_PORT=8549

PRYSM_BEACON_RPC_PORT=4000
PRYSM_BEACON_GRPC_GATEWAY_PORT=4100
PRYSM_BEACON_P2P_TCP_PORT=4200
PRYSM_BEACON_P2P_UDP_PORT=4300
PRYSM_BEACON_MONITORING_PORT=4400

PRYSM_VALIDATOR_RPC_PORT=7000
PRYSM_VALIDATOR_GRPC_GATEWAY_PORT=7100
PRYSM_VALIDATOR_MONITORING_PORT=7200

trap 'echo "Error on line $LINENO"; exit 1' ERR

# Function to handle the cleanup
cleanup() {
    echo "Caught Ctrl+C. Killing active background processes and exiting."
    kill $(jobs -p)  # Kills all background processes started in this script
    exit
}

# Trap the SIGINT signal and call the cleanup function when it's caught
trap 'cleanup' SIGINT

# Reset the data from any previous runs and kill any hanging runtimes
rm -rf "$NETWORK_DIR" || echo "no network directory"
mkdir -p $NETWORK_DIR
pkill geth || echo "No existing geth processes"
pkill beacon-chain || echo "No existing beacon-chain processes"
pkill validator || echo "No existing validator processes"
pkill bootnode || echo "No existing bootnode processes"

# Set Paths for your binaries. Configure as you wish, particularly
# if you're developing on a local fork of geth/prysm
GETH_BINARY=./dependencies/go-ethereum/build/bin/geth
GETH_BOOTNODE_BINARY=./dependencies/go-ethereum/build/bin/bootnode
PRYSM_CTL_BINARY=./dependencies/prysm/out/prysmctl
PRYSM_BEACON_BINARY=./dependencies/prysm/out/beacon-chain
PRYSM_VALIDATOR_BINARY=./dependencies/prysm/out/validator

# Create the bootnode for execution client peer discovery. 
# Not a production grade bootnode. Does not do peer discovery for consensus client
mkdir -p $NETWORK_DIR/bootnode

# Generate the genesis. This will generate validators based
# on https://github.com/ethereum/eth2.0-pm/blob/a085c9870f3956d6228ed2a40cd37f0c6580ecd7/interop/mocked_start/README.md
# We want to start our nodes before the gensis time of the chain
$PRYSM_CTL_BINARY testnet generate-genesis \
--fork=capella \
--num-validators=$NUM_NODES \
--genesis-time-delay=15 \
--output-ssz=$NETWORK_DIR/genesis.ssz \
--chain-config-file=./config.yml \
--geth-genesis-json-in=./genesis.json \
--geth-genesis-json-out=$NETWORK_DIR/genesis.json


# The prysm bootstrap node is set after the first loop, as the first
# node is the bootstrap node. This is used for consensus client discovery
PRYSM_BOOTSTRAP_NODE=


NODE_DIR=$NETWORK_DIR/node0
mkdir -p $NODE_DIR/execution
mkdir -p $NODE_DIR/consensus
mkdir -p $NODE_DIR/logs

# We use an empty password. Do not do this in production
geth_pw_file="$NODE_DIR/geth_password.txt"
echo "" > "$geth_pw_file"

# Copy the same genesis and inital config the node's directories
cp ./config.yml $NODE_DIR/consensus/config.yml
cp $NETWORK_DIR/genesis.ssz $NODE_DIR/consensus/genesis.ssz
cp $NETWORK_DIR/genesis.json $NODE_DIR/execution/genesis.json

# Create the secret keys for this node and other account details
$GETH_BINARY account new --datadir "$NODE_DIR/execution" --password "$geth_pw_file"

# Initialize geth for this node. Geth uses the genesis.json to write some initial state
$GETH_BINARY init \
      --datadir=$NODE_DIR/execution \
      $NODE_DIR/execution/genesis.json

# Start geth execution client for this node
$GETH_BINARY \
      --networkid=${CHAIN_ID:-32382} \
      --http \
      --http.api=eth,net,web3 \
      --http.addr=0.0.0.0 \
      --http.corsdomain="*" \
      --ws \
      --ws.api=eth,net,web3 \
      --ws.addr=0.0.0.0 \
      --ws.origins="*" \
      --authrpc.vhosts="*" \
      --authrpc.addr=0.0.0.0 \
      --authrpc.jwtsecret=$NODE_DIR/execution/jwtsecret \
      --datadir=$NODE_DIR/execution \
      --password=$geth_pw_file \
      --verbosity=3 \
      --syncmode=full \
      --nat extip:4.240.105.79 > "$NODE_DIR/logs/geth.log" 2>&1 &

sleep 5

# Start prysm consensus client for this node
$PRYSM_BEACON_BINARY \
      --datadir=$NODE_DIR/consensus/beacondata \
      --min-sync-peers=0 \
      --genesis-state=$NODE_DIR/consensus/genesis.ssz \
      --bootstrap-node=$PRYSM_BOOTSTRAP_NODE \
      --interop-eth1data-votes \
      --chain-config-file=$NODE_DIR/consensus/config.yml \
      --contract-deployment-block=0 \
      --chain-id=${CHAIN_ID:-32382} \
      --rpc-host=0.0.0.0 \
      --grpc-gateway-host=0.0.0.0 \
      --execution-endpoint=http://0.0.0.0:8551 \
      --accept-terms-of-use \
      --jwt-secret=$NODE_DIR/execution/jwtsecret \
      --suggested-fee-recipient=0x123463a4b065722e99115d6c222f267d9cabb524 \
      --minimum-peers-per-subnet=0 \
      --enable-debug-rpc-endpoints \
      --p2p-host-ip=4.240.105.79 \
      --minimum-peers-per-subnet=0 \
      --monitoring-port=$PRYSM_BEACON_MONITORING_PORT \
      --verbosity=info \
      --slasher \
      --enable-debug-rpc-endpoints > "$NODE_DIR/logs/beacon.log" 2>&1 &
# Start prysm validator for this node. Each validator node will manage 1 validator
$PRYSM_VALIDATOR_BINARY \
      --beacon-rpc-provider=localhost:$PRYSM_BEACON_RPC_PORT \
      --datadir=$NODE_DIR/consensus/validatordata \
      --accept-terms-of-use \
      --interop-num-validators=$NUM_NODES \
      --interop-start-index=0 \
      --chain-config-file=$NODE_DIR/consensus/config.yml > "$NODE_DIR/logs/validator.log" 2>&1 &
done

#!/usr/bin/env bash
set -e
pkg update -y && pkg upgrade -y
pkg install -y git nodejs-lts wget curl vim jq openssl
cd contracts && npm install && cd ..
cd backend && npm install && cd ..

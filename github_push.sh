#!/usr/bin/env bash
set -e
[ -f .env ] || (echo ".env missing"; exit 1)
source .env
[ -n "$GITHUB_TOKEN" ] || (echo "GITHUB_TOKEN missing"; exit 1)
NAME=${1:-tgst-empire}
curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user/repos -d "{\"name\":\"$NAME\",\"private\":true}" >/dev/null
git init && git add . && git commit -m "TGST Empire initial"
git branch -M main
USER=$(curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user | jq -r .login)
git remote add origin https://github.com/$USER/$NAME.git
git push -u origin main

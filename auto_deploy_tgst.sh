#!/bin/bash
while true; do
  echo "⏱ Vérification des nouvelles mises à jour depuis GitHub..."
  git pull origin main
  vercel --prod --confirm
  sleep 300
done

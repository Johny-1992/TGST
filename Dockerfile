# Utiliser une image officielle Node + Python
FROM node:18

# Installer Python
RUN apt-get update && apt-get install -y python3 python3-pip

# Créer un dossier de travail
WORKDIR /app

# Copier tout ton projet TGST
COPY . .

# Rendre ton script maître exécutable
RUN chmod +x launch_tgst.sh

# Installer dépendances Node et Python globales si besoin
RUN npm install -g npm@latest

# Commande de démarrage → ton orchestrateur
CMD ["bash", "launch_tgst.sh"]

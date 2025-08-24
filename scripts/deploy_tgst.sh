#!/bin/bash

# Aller dans le repo TGST
cd ~/TGST || exit

echo "✅ Début du déploiement TGST"

# 1️⃣ Créer dossier assets et déplacer le logo
mkdir -p assets
mv 'file_0000000091ec61fdb5c5257a796dbd53 (1).png' assets/logo.png 2>/dev/null
echo "✅ Logo déplacé dans assets/logo.png"

# 2️⃣ Générer index.html avec README intégré et logo
README_CONTENT=$(cat README.md | sed 's/</\&lt;/g; s/>/\&gt;/g')
cat > index.html <<EOL
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>TGST Ecosystem</title>
  <link rel="stylesheet" href="css/style.css">
</head>
<body>
  <header>
    <img src="assets/logo.png" alt="TGST Logo" width="70">
    <h1>🚀 Welcome to TGST Ecosystem</h1>
  </header>
  <main>
    <section id="intro">
      <pre>$README_CONTENT</pre>
    </section>
    <section id="services">
      <ul>
        <li><a href="dashboard.html">Dashboard</a></li>
        <li><a href="bot.html">Bot</a></li>
        <li><a href="app.html">App</a></li>
      </ul>
    </section>
  </main>
</body>
</html>
EOL
echo "✅ index.html généré avec README et logo"

# 3️⃣ Créer dashboard.html avec Smart Contract TGST
cat > dashboard.html <<EOL
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>TGST Dashboard</title>
  <link rel="stylesheet" href="css/style.css">
</head>
<body>
  <header>
    <img src="assets/logo.png" alt="TGST Logo" width="50">
    <h1>TGST Dashboard</h1>
  </header>
  <main>
    <p>Smart Contract TGST :</p>
    <pre id="contract">0xYOUR_TGST_CONTRACT_ADDRESS</pre>
  </main>
</body>
</html>
EOL
echo "✅ dashboard.html créé avec Smart Contract"

# 4️⃣ Créer pages bot.html et app.html
cat > bot.html <<EOL
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>TGST Bot</title>
</head>
<body>
  <header><h1>TGST Bot</h1></header>
  <main>
    <p>Intégrer ici ton script Bot existant (App.js / main.jsx)</p>
  </main>
</body>
</html>
EOL

cat > app.html <<EOL
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>TGST App</title>
</head>
<body>
  <header><h1>TGST App</h1></header>
  <main>
    <p>Intégrer ici ton application mobile / PWA (App.js / App.jsx)</p>
  </main>
</body>
</html>
EOL
echo "✅ bot.html et app.html créés"

# 5️⃣ Créer structure CSS simple
mkdir -p css
cat > css/style.css <<EOL
body { font-family: Arial, sans-serif; background: #f0f2f5; color: #111; margin: 0; padding: 0; }
header { background: #0a0a0a; color: #fff; padding: 20px; text-align: center; }
main { padding: 20px; }
a { color: #0070f3; text-decoration: none; margin-right: 15px; }
pre { background: #eee; padding: 10px; overflow-x: auto; }
EOL
echo "✅ CSS généré"

# 6️⃣ Installer toutes les dépendances si non fait
yarn install

# 7️⃣ Build Next.js / React si applicable
if [ -f package.json ]; then
  if grep -q "next" package.json; then
    echo "✅ Build Next.js..."
    yarn build
  elif grep -q "react-scripts" package.json; then
    echo "✅ Build React..."
    yarn build
  fi
fi

# 8️⃣ Déploiement Vercel (si CLI installé et connecté)
if command -v vercel >/dev/null 2>&1; then
  echo "🚀 Déploiement sur Vercel..."
  vercel --prod --confirm
else
  echo "⚠️ Vercel CLI non installé. Site prêt localement dans ~/TGST"
fi

echo "🎉 Déploiement TGST terminé !"

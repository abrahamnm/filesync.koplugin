# FileSync - Gestionnaire de fichiers sans fil pour KOReader

[English](README.md) | [Español](README.es.md) | [Português](README.pt_BR.md) | [中文](README.zh_CN.md) | [العربية](README.ar.md) | **Français** | [Deutsch](README.de.md) | [Русский](README.ru.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

Un plugin KOReader qui lance un serveur web local sur votre liseuse et affiche un QR code à l'écran. Scannez le code avec votre téléphone pour ouvrir une interface web soignée permettant de gérer vos livres et fichiers sans fil — pas de câbles, pas d'applications, juste votre navigateur.

Fonctionne sur les appareils sous KOReader (conçu pour **Kindle** et **Kobo**).

<p align="center">
  <img src="screenshots/qr-screen.png" alt="Écran du QR code sur la liseuse" width="500">
</p>
<p align="center">
  <img src="screenshots/web-home.png" alt="Interface web - accueil" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Interface web - navigation" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Interface web - détail du fichier" width="250">
</p>

## Fonctionnalités

- **Accès par QR code** — Scannez pour vous connecter instantanément, sans saisir d'URL
- **Explorateur de fichiers** — Parcourez votre bibliothèque avec un fil d'Ariane
- **Envoi de fichiers** — Glissez-déposez ou appuyez pour envoyer des livres depuis votre téléphone
- **Téléchargement de fichiers** — Enregistrez n'importe quel fichier sur votre téléphone en un clic
- **Création de dossiers** — Organisez votre bibliothèque en répertoires
- **Renommage et suppression** — Gestion de fichiers simplifiée avec boîtes de dialogue de confirmation
- **Recherche et tri** — Filtrage par nom, tri par nom/taille/date/type
- **Thèmes sombre et clair** — Détection automatique ou basculement manuel
- **Modes d'affichage multiples** — Vues en liste, grille et grande grille
- **Support multilingue** — Disponible en 10 langues (anglais, espagnol, portugais, chinois, arabe, français, allemand, russe, japonais, coréen)
- **Support de la mise en page RTL** — Mise en page complète de droite à gauche pour l'arabe
- **Prévention de la veille** — Maintient l'appareil éveillé et le WiFi actif pendant l'exécution du serveur
- **Mode sécurisé** — Affiche uniquement les livres et images, en masquant les fichiers système
- **Interface adaptative** — Conçue pour les smartphones, fonctionne sur tout écran

## Comment ça marche

1. Connectez votre liseuse au WiFi
2. Ouvrez le plugin FileSync depuis le menu Outils réseau de KOReader
3. Un QR code apparaît sur l'écran de la liseuse
4. Scannez-le avec votre téléphone (connecté au même réseau WiFi)
5. Gérez vos livres depuis l'interface web dans le navigateur de votre téléphone

## Installation

### Prérequis

- Un appareil avec [KOReader](https://github.com/koreader/koreader) installé
- Votre liseuse et votre téléphone connectés au même réseau WiFi

### Option 1 : Depuis l'archive de la version (recommandé)

1. Téléchargez le dernier fichier `.zip` depuis la page des [versions](../../releases)
2. Extrayez l'archive
3. Copiez le dossier `filesync.koplugin` dans le répertoire des plugins KOReader de votre appareil (voir les chemins ci-dessous)
4. Redémarrez KOReader

### Option 2 : Copie directe

1. Connectez votre liseuse à votre ordinateur via USB

2. Localisez le répertoire des plugins KOReader :
   - **Kindle :** `/mnt/us/koreader/plugins/`
   - **Kobo :** `.adds/koreader/plugins/` (à la racine de la carte SD)

3. Copiez l'intégralité du dossier `filesync.koplugin` dans le répertoire des plugins :
   ```
   plugins/
   ├── filesync.koplugin/
   │   ├── _meta.lua
   │   ├── main.lua
   │   └── filesync/
   │       ├── filesyncmanager.lua
   │       ├── httpserver.lua
   │       ├── fileops.lua
   │       ├── filesync_i18n.lua
   │       ├── json.lua
   │       ├── mobi.lua
   │       ├── utils.lua
   │       ├── static/
   │       │   └── index.html
   │       └── i18n/
   │           ├── en.po
   │           ├── es.po
   │           ├── pt_BR.po
   │           ├── zh_CN.po
   │           ├── ar.po
   │           ├── fr.po
   │           └── ...
   ├── other.koplugin/
   └── ...
   ```

4. Éjectez l'appareil en toute sécurité et redémarrez KOReader

### Vérification de l'installation

Après le redémarrage de KOReader, ouvrez le menu supérieur et accédez à :

**Network → FileSync**

Si l'entrée de menu apparaît, le plugin est correctement installé.

## Utilisation

### Démarrage du serveur

0. Assurez-vous que votre appareil est connecté au WiFi
1. Ouvrez le menu supérieur de KOReader
2. Accédez à **Network → FileSync**
3. Appuyez sur **Start file server**
4. Un QR code apparaîtra à l'écran avec l'URL de connexion

<p align="center">
  <img src="screenshots/menu.png" alt="Menu FileSync dans KOReader" width="350">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/qr-screen.png" alt="Écran du QR code" width="350">
</p>

### Connexion depuis votre téléphone

1. Assurez-vous que votre téléphone est sur le **même réseau WiFi** que la liseuse
2. Ouvrez l'appareil photo de votre téléphone et scannez le QR code
3. Appuyez sur le lien pour ouvrir l'interface web dans votre navigateur
4. Vous pouvez également saisir manuellement l'URL affichée sous le QR code

### Gestion des fichiers

Une fois connecté, l'interface web vous permet de :

- **Parcourir** — Appuyez sur les dossiers pour naviguer dans votre bibliothèque. Utilisez le fil d'Ariane en haut pour revenir à n'importe quel répertoire parent.
- **Envoyer** — Appuyez sur le bouton **Upload** dans l'en-tête, puis choisissez des fichiers ou glissez-les dans la zone de dépôt. Plusieurs fichiers peuvent être envoyés simultanément.
- **Détails du fichier** — Appuyez sur n'importe quel fichier pour ouvrir sa vue détaillée, où vous pouvez le **télécharger**, le **renommer** ou le **supprimer**.
- **Créer des dossiers** — Appuyez sur le bouton **Folder** dans l'en-tête et saisissez un nom.
- **Rechercher** — Utilisez la barre de recherche pour filtrer le répertoire actuel par nom de fichier.
- **Trier** — Utilisez le menu déroulant pour trier par nom, date, taille ou type, en ordre croissant ou décroissant.

<p align="center">
  <img src="screenshots/web-home.png" alt="Explorateur de fichiers - accueil" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Explorateur de fichiers - répertoire avec envoi" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Vue détaillée du fichier" width="250">
</p>

### Prévention de la veille

Pendant l'exécution du serveur de fichiers, le plugin empêche automatiquement votre appareil de se mettre en veille ou de se suspendre. Cela maintient le serveur accessible et le WiFi connecté sans interruption. Concrètement :

- La **mise en veille** et la **suspension** sont bloquées pour garder l'appareil actif
- Les minuteurs de **suspension automatique** et de **mise en veille automatique** sont temporairement désactivés
- Le **maintien de la connexion WiFi** est activé pour préserver la connexion réseau

Tous les paramètres sont restaurés à leurs valeurs précédentes lorsque le serveur est arrêté. Si l'appareil se suspend malgré tout (par exemple en raison d'une batterie critique), le serveur redémarrera automatiquement au réveil de l'appareil.

### Arrêt du serveur

- Appuyez sur **Stop file server** dans le menu du plugin, ou
- Le serveur s'arrête automatiquement lorsque vous quittez KOReader

### Changement de port

1. Ouvrez le menu du plugin
2. Appuyez sur **Server port**
3. Saisissez un numéro de port entre 1024 et 65535 (par défaut : 8080)
4. Redémarrez le serveur pour appliquer le changement

### Mode sécurisé

Le mode sécurisé est **activé par défaut** et limite l'interface web à l'affichage des fichiers pertinents pour votre bibliothèque de lecture. Lorsqu'il est activé :

- Seuls les **livres numériques** (EPUB, PDF, MOBI, AZW3, FB2, DJVU, CBZ, etc.), les **documents** (TXT, DOC, RTF, HTML, etc.) et les **images** (JPG, PNG, GIF, WebP) sont affichés
- Les fichiers système, les fichiers de configuration et les autres fichiers non liés aux livres sont masqués
- Les répertoires de métadonnées KOReader (dossiers `.sdr`) sont masqués et automatiquement nettoyés lors de la suppression d'un livre

Pour activer ou désactiver le mode sécurisé, ouvrez le menu du plugin et appuyez sur **Safe mode**. Le désactiver affichera tous les fichiers présents sur l'appareil.

## Dépannage

**Le plugin n'apparaît pas dans le menu**
- Vérifiez que le dossier est nommé exactement `filesync.koplugin` (sensible à la casse)
- Vérifiez que `_meta.lua` et `main.lua` sont directement dans le dossier (pas dans un sous-dossier)
- Redémarrez complètement KOReader

**Erreur « WiFi is not enabled »**
- Connectez votre liseuse à un réseau WiFi avant de démarrer le serveur
- Certains appareils nécessitent d'activer explicitement le WiFi dans les paramètres réseau de KOReader

**Le téléphone ne peut pas se connecter**
- Vérifiez que les deux appareils sont sur le même réseau WiFi
- Essayez de saisir l'URL manuellement au lieu de scanner le QR code
- Vérifiez si l'isolation des clients est activée sur votre routeur (empêche les appareils de se voir mutuellement)
- Sur Kindle : le plugin gère automatiquement les règles de pare-feu, mais un redémarrage peut aider si les règles sont bloquées

**Échec de l'envoi**
- Vérifiez l'espace de stockage disponible sur l'appareil
- Les fichiers très volumineux peuvent dépasser le délai d'attente — essayez d'envoyer des lots plus petits
- Assurez-vous que le répertoire cible est accessible en écriture
- La taille maximale d'envoi est de 1 Go par fichier

**L'envoi de fichiers volumineux ralentit l'appareil**
- L'envoi de fichiers de plus de 100 Mo peut rendre temporairement l'interface de la liseuse non réactive pendant le transfert. C'est normal — l'appareil a une puissance de traitement limitée. L'interface se rétablira une fois l'envoi terminé.

## Contribuer

Les contributions sont les bienvenues !

1. Forkez le dépôt
2. Créez une branche pour votre fonctionnalité
3. Effectuez vos modifications
4. Exécutez les tests (voir ci-dessous)
5. Testez sur un appareil réel si possible
6. Soumettez une pull request

### Exécuter les tests

Le projet utilise [busted](https://lunarmodules.github.io/busted/) pour les tests unitaires. Les tests couvrent les fonctions de logique pure (encodage/décodage JSON, validation des chemins, analyse des versions, etc.) et ne nécessitent pas d'environnement KOReader.

**Installer busted** (si non installé) :

```bash
luarocks install busted
```

**Exécuter tous les tests :**

```bash
busted
```

Cela exécute plus de 177 tests répartis dans 5 fichiers de test. Vous devriez voir une sortie similaire à :

```
177 successes / 0 failures / 0 errors / 0 pending : 0.04 seconds
```

**Exécuter un fichier de test spécifique :**

```bash
busted spec/json_spec.lua
```

**Fichiers de test :**

| Fichier | Couverture |
|---------|------------|
| `spec/json_spec.lua` | Encodage/décodage JSON aller-retour, cas limites, gestion des erreurs |
| `spec/fileops_spec.lua` | Prévention du path traversal, validation des noms de fichiers, formatage des tailles, types MIME |
| `spec/updater_spec.lua` | Analyse des versions, comparaison des versions, extraction du changelog |
| `spec/utils_spec.lua` | Résolution du répertoire du plugin, échappement shell |
| `spec/httpserver_spec.lua` | Décodage d'URL, analyse des chaînes de requête |

Lors de l'ajout de nouvelles fonctionnalités, veuillez inclure les tests correspondants pour toute fonction de logique pure.

## Licence

Ce projet est distribué sous licence [AGPLv3](https://www.gnu.org/licenses/agpl-3.0.html), conformément au projet KOReader.

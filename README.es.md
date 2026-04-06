# FileSync - Gestor de Archivos Inalámbrico para KOReader

[English](README.md) | **Español** | [Português](README.pt_BR.md) | [中文](README.zh_CN.md) | [العربية](README.ar.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

Un plugin para KOReader que inicia un servidor web local en tu lector electrónico y muestra un código QR en pantalla. Escanea el código con tu teléfono para abrir una interfaz web elegante que te permite gestionar libros y archivos de forma inalámbrica — sin cables, sin apps, solo tu navegador.

Funciona en dispositivos **Kindle** y **Kobo** con KOReader instalado.

<p align="center">
  <img src="screenshots/qr-screen.png" alt="Código QR en la pantalla del lector electrónico" width="500">
</p>
<p align="center">
  <img src="screenshots/web-home.png" alt="Interfaz web - inicio" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Interfaz web - directorio" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Interfaz web - detalle de archivo" width="250">
</p>

## Funcionalidades

- **Acceso por QR** — Escanea para conectarte al instante, sin escribir URLs
- **Explorador de Archivos** — Navega tu biblioteca con migas de pan (breadcrumbs)
- **Subir Archivos** — Arrastra y suelta o toca para subir libros desde tu teléfono
- **Descargar Archivos** — Guarda cualquier archivo en tu teléfono con un solo toque
- **Crear Carpetas** — Organiza tu biblioteca en directorios
- **Renombrar y Eliminar** — Gestión básica de archivos con diálogos de confirmación
- **Búsqueda y Ordenación** — Filtra por nombre, ordena por nombre/tamaño/fecha/tipo
- **Temas Claro y Oscuro** — Detectados automáticamente o seleccionados manualmente
- **Múltiples Vistas** — Vista de lista, cuadrícula y cuadrícula grande
- **Soporte Multiidioma** — Disponible en 10 idiomas (inglés, español, portugués, chino, árabe, francés, alemán, ruso, japonés, coreano)
- **Soporte para RTL** — Diseño completo de derecha a izquierda para árabe
- **Prevención de Suspensión** — Mantiene el dispositivo activo y el WiFi conectado mientras el servidor está en ejecución
- **Modo Seguro** — Muestra solo libros e imágenes, ocultando archivos del sistema
- **Interfaz Adaptable** — Diseñada para smartphones, funciona en cualquier pantalla

## Cómo Funciona

1. Conecta tu lector electrónico a una red WiFi
2. Abre el plugin FileSync desde el menú Herramientas de Red de KOReader
3. Aparecerá un código QR en la pantalla del lector
4. Escanéalo con tu teléfono (conectado a la misma red WiFi)
5. Gestiona tus libros desde la interfaz web en el navegador de tu teléfono

## Instalación

### Requisitos previos

- Un lector electrónico Kindle o Kobo con [KOReader](https://github.com/koreader/koreader) instalado
- Tu lector electrónico y tu teléfono conectados a la misma red WiFi

### Opción 1: Desde el archivo de lanzamiento (Recomendado)

1. Descarga el último archivo `.zip` de la página de [Lanzamientos](../../releases)
2. Extrae el archivo comprimido
3. Copia la carpeta `filesync.koplugin` al directorio de plugins de KOReader en tu dispositivo (consulta las rutas arriba)
4. Reinicia KOReader

### Opción 2: Copia directa

1. Conecta tu lector electrónico a tu computadora por USB

2. Localiza el directorio de plugins de KOReader:
   - **Kindle:** `/mnt/us/koreader/plugins/`
   - **Kobo:** `.adds/koreader/plugins/` (en la raíz de la tarjeta SD)

3. Copia la carpeta completa `filesync.koplugin` dentro del directorio de plugins:
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
   │       ├── qrcode.lua
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

4. Expulsa de forma segura y reinicia KOReader

### Verificar la instalación

Después de reiniciar KOReader, abre el menú superior y navega a:

**Red → FileSync**

Si ves la entrada en el menú, el plugin está correctamente instalado.

## Uso

### Iniciar el servidor

0. Asegúrate de que tu dispositivo esté conectado a una red WiFi
1. Abre el menú superior de KOReader
2. Navega a **Red → FileSync**
3. Toca **Iniciar servidor de archivos**
4. Aparecerá un código QR en pantalla con la URL de conexión

<p align="center">
  <img src="screenshots/menu.png" alt="Menú de FileSync en KOReader" width="350">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/qr-screen.png" alt="Pantalla con código QR" width="350">
</p>

### Conectarse desde tu teléfono

1. Asegúrate de que tu teléfono esté en la **misma red WiFi** que el lector electrónico
2. Abre la cámara de tu teléfono y escanea el código QR
3. Toca el enlace para abrir la interfaz web en tu navegador
4. También puedes escribir manualmente la URL que aparece debajo del código QR

### Gestionar archivos

Una vez conectado, la interfaz web te permite:

- **Explorar** — Toca las carpetas para navegar por tu biblioteca. Usa la barra de migas de pan en la parte superior para volver a cualquier directorio anterior.
- **Subir** — Toca el botón **Subir** en la barra superior, luego selecciona archivos o arrástralos a la zona de carga. Se pueden subir varios archivos a la vez.
- **Detalles del archivo** — Toca cualquier archivo para ver su detalle, donde puedes **descargarlo**, **renombrarlo** o **eliminarlo**.
- **Crear carpetas** — Toca el botón **Carpeta** en la barra superior e ingresa un nombre.
- **Buscar** — Usa la barra de búsqueda para filtrar el directorio actual por nombre de archivo.
- **Ordenar** — Usa el menú desplegable para ordenar por nombre, fecha, tamaño o tipo en orden ascendente o descendente.

<p align="center">
  <img src="screenshots/web-home.png" alt="Explorador de archivos - inicio" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Explorador de archivos - directorio con carga" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Vista de detalle de archivo" width="250">
</p>

### Prevención de suspensión

Mientras el servidor de archivos está en ejecución, el plugin evita automáticamente que tu dispositivo entre en modo de suspensión. Esto mantiene el servidor accesible y el WiFi conectado sin interrupciones. En concreto:

- Los modos de **espera** y **suspensión** se bloquean para que el dispositivo permanezca activo
- Los temporizadores de **auto-suspensión** y **auto-espera** se desactivan temporalmente
- Se activa el **keepalive de WiFi** para mantener la conexión de red

Todos los ajustes se restauran a sus valores anteriores cuando se detiene el servidor. Si el dispositivo entra en suspensión por algún motivo (por ejemplo, batería críticamente baja), el servidor se reiniciará automáticamente cuando el dispositivo despierte.

### Detener el servidor

- Toca **Detener servidor de archivos** en el menú del plugin, o
- El servidor se detiene automáticamente cuando cierras KOReader

### Cambiar el puerto

1. Abre el menú del plugin
2. Toca **Puerto del servidor**
3. Ingresa un número de puerto entre 1024 y 65535 (por defecto: 8080)
4. Reinicia el servidor para que el cambio surta efecto

### Modo Seguro

El modo seguro está **activado por defecto** y limita la interfaz web para mostrar solo archivos relevantes para tu biblioteca de lectura. Cuando está activado:

- Solo se muestran **libros electrónicos** (EPUB, PDF, MOBI, AZW3, FB2, DJVU, CBZ, etc.), **documentos** (TXT, DOC, RTF, HTML, etc.) e **imágenes** (JPG, PNG, GIF, WebP)
- Los archivos del sistema, archivos de configuración y otros archivos no relacionados con libros se ocultan
- Los directorios de metadatos de KOReader (carpetas `.sdr`) se ocultan y se limpian automáticamente al eliminar un libro

Para alternar el modo seguro, abre el menú del plugin y toca **Modo seguro**. Desactivarlo mostrará todos los archivos del dispositivo.

## Solución de problemas

**El plugin no aparece en el menú**
- Asegúrate de que la carpeta se llame exactamente `filesync.koplugin` (distingue mayúsculas y minúsculas)
- Verifica que `_meta.lua` y `main.lua` estén directamente dentro de la carpeta (no en subcarpetas)
- Reinicia KOReader completamente

**Error "WiFi no está activado"**
- Conecta tu lector electrónico a una red WiFi antes de iniciar el servidor
- Algunos dispositivos requieren que el WiFi se active explícitamente en los ajustes de red de KOReader

**El teléfono no puede conectarse**
- Verifica que ambos dispositivos estén en la misma red WiFi
- Intenta escribir la URL manualmente en lugar de escanear el código QR
- Comprueba si tu router tiene activado el aislamiento de clientes (impide que los dispositivos se vean entre sí)
- En Kindle: el plugin gestiona las reglas del firewall automáticamente, pero un reinicio puede ayudar si las reglas están atascadas

**La subida de archivos falla**
- Verifica el espacio de almacenamiento disponible en el dispositivo
- Los archivos muy grandes pueden agotar el tiempo de espera — intenta subir en lotes más pequeños
- Asegúrate de que el directorio de destino tenga permisos de escritura

## Contribuir

¡Las contribuciones son bienvenidas!

1. Haz un fork del repositorio
2. Crea una rama para tu funcionalidad
3. Realiza tus cambios
4. Prueba en un dispositivo real si es posible
5. Envía un pull request

## Licencia

Este proyecto está licenciado bajo la [AGPLv3](https://www.gnu.org/licenses/agpl-3.0.html), en consonancia con el proyecto KOReader.

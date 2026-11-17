# Apuntes

Tu app de apuntes a mano (Apple Pencil) y con teclado, alojada en tu propio ordenador.

- **iPad / navegador**: versión web, que se instala desde Safari como una app más.
- **Android**: APK que se descarga desde la sección *Releases* de este repositorio.
- **Servidor**: un contenedor Docker en tu ordenador de casa. Llega a tus dispositivos por **Tailscale**, sin abrir puertos al exterior.

## Qué hace (versión 0.1)

- Cuadernos con tapa de color y papel en blanco, rayado, cuadrícula o puntos.
- Pluma sensible a la presión, marcador, borrador de trazos y cajas de texto escritas con el teclado.
- Rechazo de la palma: con el lápiz se escribe y con los dedos se mueve la página o se hace zoom.
- Deshacer y rehacer; añadir, insertar y eliminar páginas.
- Funciona sin conexión y sincroniza solo cuando vuelve a haber conexión.

## Cómo se compila

Cada vez que se sube un cambio a la rama `main`, GitHub Actions hace dos cosas:

1. Crea la imagen Docker `ghcr.io/<tu-usuario>/apuntes:latest`, que lleva el servidor y la app web.
2. Compila la app de Android y la publica en *Releases*.

## Instalación en casa (Windows + Docker + Portainer)

### 1. Hacer pública la imagen (una sola vez)
En GitHub: tu perfil → **Packages** → **apuntes** → *Package settings* → *Change visibility* → **Public**.
La imagen solo contiene el programa. Tus apuntes y tu contraseña no salen nunca de tu ordenador.

### 2. Crear el stack en Portainer
1. Ve a **Stacks** → **Add stack**, ponle el nombre `apuntes` y elige **Web editor**.
2. Pega el contenido de `docker-compose.yml` y cambia `cambia-esta-contraseña` por una contraseña tuya (mínimo 8 caracteres).
3. Pulsa **Deploy the stack**. Para comprobar que funciona, abre `http://localhost:8080` en el PC: debe aparecer la pantalla de entrada.

### 3. Tailscale (acceso seguro desde el iPad, también fuera de casa)
1. Crea una cuenta gratuita en tailscale.com. Instala Tailscale en el PC con Windows y en el iPad, con la misma cuenta.
2. En la consola web de Tailscale → **DNS**: activa *MagicDNS* y *HTTPS Certificates*.
3. En el PC, abre **PowerShell** y ejecuta:
   ```
   tailscale serve --bg 8080
   ```
   El comando te mostrará una dirección del tipo `https://nombre-del-pc.tu-red.ts.net`.

### 4. En el iPad
1. Con Tailscale activado, abre esa dirección en **Safari**.
2. Pulsa Compartir → **Añadir a pantalla de inicio**.
3. Abre Apuntes desde el icono y entra con tu contraseña.

### 5. En Android (opcional)
Descarga `app-release.apk` desde *Releases*, instálalo y escribe la misma dirección y contraseña.

## Actualizar
Cuando haya una versión nueva: en Portainer → Stacks → apuntes → **Update the stack**, con la opción *Re-pull image* activada.

## Copias de seguridad
Tus apuntes están en el volumen de Docker `apuntes_apuntes-datos`. Además, siempre hay una copia completa en cada dispositivo donde hayas abierto la app.

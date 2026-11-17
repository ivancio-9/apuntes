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

## Instalación en casa (una sola vez)

### 1. Docker
Instala **Docker Desktop** (Windows/Mac) o **Docker Engine** (Linux) en el ordenador que hará de servidor.

### 2. Imagen pública
En GitHub, entra en tu perfil → **Packages** → **apuntes** → *Package settings* → *Change visibility* → **Public**.
La imagen solo contiene el programa. Tus apuntes y tu contraseña no salen nunca de tu ordenador.

### 3. Arrancar el servidor
1. Crea una carpeta, por ejemplo `apuntes-servidor`, y copia dentro `docker-compose.yml`.
2. Edita el archivo: pon tu usuario de GitHub **en minúsculas** donde dice `USUARIO` y elige una contraseña.
3. Abre una terminal en esa carpeta y ejecuta:
   ```
   docker compose up -d
   ```

### 4. Tailscale (acceso seguro desde el iPad, también fuera de casa)
1. Crea una cuenta gratuita en tailscale.com e instala Tailscale en el ordenador y en el iPad, con la misma cuenta.
2. En la consola web de Tailscale → **DNS**: activa *MagicDNS* y *HTTPS Certificates*.
3. En el ordenador, ejecuta en una terminal:
   ```
   tailscale serve --bg 8080
   ```
   El comando te mostrará una dirección del tipo `https://mi-pc.tu-red.ts.net`.

### 5. En el iPad
1. Con Tailscale activado, abre esa dirección en **Safari**.
2. Pulsa Compartir → **Añadir a pantalla de inicio**.
3. Abre Apuntes desde el icono y entra con tu contraseña.

### 6. En Android (opcional)
Descarga el APK desde *Releases*, instálalo y escribe la misma dirección y contraseña.

## Actualizar
Cuando haya una versión nueva, ejecuta en la carpeta del servidor:
```
docker compose pull && docker compose up -d
```

## Copias de seguridad
Todos tus apuntes están en la carpeta `datos/` junto a `docker-compose.yml`. Para hacer una copia de seguridad, basta con copiar esa carpeta.

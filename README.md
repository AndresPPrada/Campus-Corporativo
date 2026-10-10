# Campus Corporativo MINEX

Sitio estático del campus de aprendizaje.

## Estructura

- `index.html`: página principal y catálogo.
- `admin.html`: panel para crear y editar cursos.
- `curso.html`, `curso-induccion.html`: páginas de cursos.
- `css/`: estilos globales y estilos de cada sección.
- `js/`: lógica del catálogo, panel y reproductor de cursos.
- `assets/`: imágenes y recursos gráficos.

Las páginas HTML permanecen en la raíz para que sus enlaces sean directos. Los estilos y scripts están separados por tipo de recurso.

## Acceso local de desarrollo

> **INICIO DEL CAMPUS Y PANEL ADMIN**
>
> 1. Abre PowerShell en esta carpeta y ejecuta:
>
>    ```powershell
>    powershell -NoProfile -ExecutionPolicy Bypass -File .\dev-server.ps1
>    ```
>
> 2. Deja abierta la ventana de PowerShell y visita **<http://127.0.0.1:8765/admin.html>** para entrar al panel. Para el campus, visita **<http://127.0.0.1:8765/>**.
>
> 3. **Usuario administrador:** el correo que escribas la primera vez que inicies el servidor. Si ya existe `.local-data/users.json`, usa el correo registrado allí.
>
> 4. **Clave:** la contraseña que definas durante ese primer inicio; debe tener al menos 12 caracteres. No se guarda en este README. No hay recuperación de clave en el panel provisional; respalda `.local-data/` antes de cualquier cambio manual.

El servidor local de desarrollo no requiere instalar paquetes. El administrador puede crear cuentas de colaboradores desde el panel; esas cuentas no tienen permiso para entrar al panel admin.

### Recuperar datos de otro origen local

Si los cursos se crearon desde Live Server (`http://127.0.0.1:5500`), abre allí `admin.html` y descarga una copia en **Transferir datos del campus**. Luego abre `http://127.0.0.1:8765/admin.html`, inicia sesión como administrador e importa ese archivo desde la misma sección. La copia incluye cursos, categorías, avances, comentarios y videos guardados en el navegador. Recarga el campus después de importarla.

El servidor solo escucha en `127.0.0.1`, protege las páginas de rutas, cursos y administración, aplica sesiones de ocho horas con cookie `HttpOnly` y `SameSite=Strict`, limita los intentos de acceso y almacena las contraseñas como hashes PBKDF2. Las cuentas locales quedan en `.local-data/`, que está excluida del repositorio. Detén el servidor con `Ctrl+C`.

Este acceso es solo para desarrollo en este equipo. Microsoft todavía no está conectado; su botón aparece deshabilitado hasta configurar el tenant corporativo. Los cursos, categorías, comentarios y avances todavía se guardan en el navegador y no se sincronizan entre usuarios.

## Memoria de continuidad

Usa esta sección como contexto para retomar el trabajo. La interfaz del producto y sus textos deben mantenerse en español de Colombia, con tildes y caracteres UTF-8 correctos. Conserva los nombres y títulos de rutas y categorías existentes al ajustar el diseño.

### Estado actual

- La página de inicio conserva las categorías y las rutas destacadas. Los botones de Inducción y Plan de Desarrollo ahora llevan a sus contenidos en vez de mostrar el aviso fijo que pedía iniciar sesión.
- `ruta-capacitaciones.html` presenta las categorías y sus cursos con búsqueda y filtro.
- `admin.html` crea y edita cursos, organiza categorías y permite crear cuentas locales.
- La administración de cursos permite guardar borradores, editar, previsualizar, publicar, archivar y eliminar cursos.
- El aula de cada curso organiza videos por módulos, guarda avance por cuenta local, permite comentarios y preguntas, abre evaluaciones externas y genera un comprobante imprimible.
- El login local lo sirve `dev-server.ps1` en `http://127.0.0.1:8765`. Protege las páginas privadas; solo el rol `admin` entra a `admin.html`. El botón de Microsoft sigue pendiente de configurar.
- Las cuentas están en `.local-data/users.json`, excluido del repositorio. No copiar credenciales ni secretos al README.
- Cursos, categorías, avances y comentarios usan `localStorage`; los videos subidos usan IndexedDB. Estos datos son independientes por origen/puerto y no se sincronizan entre navegadores.
- El avance se separa por correo de la sesión local. Comentarios y preguntas tienen autor, pero siguen guardándose solo en el navegador y no se sincronizan entre colaboradores.
- La evaluación se inserta como formulario externo cuando el proveedor permite iframes; el usuario puede abrirla en otra pestaña si no carga. La confirmación de evaluación es manual: el servidor local no puede comprobar la nota de Microsoft Forms u otro proveedor. El certificado es un comprobante local imprimible, no una certificación validada por MINEX.
- Se agregó **Transferir datos del campus** al panel: exporta las claves `minex-*` y los videos de IndexedDB a un JSON e importa esa copia en otro origen. Si hay claves iguales, la importación las reemplaza y pide confirmación.

### Próximo paso pendiente

Completa la migración de los datos anteriores: abre `http://127.0.0.1:5500/admin.html` con Live Server, descarga la copia desde **Transferir datos del campus**, abre `http://127.0.0.1:8765/admin.html` con el servidor local, inicia sesión como administrador, importa el JSON y recarga el campus. Comprueba que aparezcan cursos, categorías y videos. La transferencia ya está implementada, pero falta validar el flujo real con los datos del navegador.

Después de validar la migración, revisar visualmente el flujo de borrador/publicación/archivo y el aula del curso con un curso de prueba. No ejecutar esa validación con cursos reales sin exportar primero una copia.

La conexión de Microsoft Entra y el almacenamiento compartido de cursos todavía no están implementados. La evaluación externa tampoco valida automáticamente resultados, y el certificado actual es local. Para convertir comentarios, progreso y certificados en datos corporativos, se requiere un backend con permisos y persistencia compartida. Antes de cambiar persistencia, conservar una copia exportada de los datos locales.

# NinjaFlixConfig

Catálogo remoto público de NinjaFlix. Contiene metadatos, enlaces a las
fuentes y recursos gráficos; los archivos de video no se almacenan aquí.

## Actualización local

Se necesita Dart 3.12.2 o posterior:

```powershell
dart pub get
dart run tool/update_catalog.dart
```

El actualizador rastrea el sitio fuente, valida que la descarga esté completa
y solo reemplaza `public/catalog.json` y `public/manifest.json` cuando
encuentra una versión válida diferente. Si una página falla, la última versión
publicada permanece intacta.

## Publicación

El workflow `publish.yml` revisa el sitio cada seis horas y también se puede
ejecutar manualmente desde la pestaña **Actions**. Cuando detecta cambios:

1. Ejecuta las pruebas del parser.
2. Genera y valida el catálogo.
3. Guarda los cambios en este repositorio.
4. Publica `public/` mediante GitHub Pages.

Después del primer despliegue, los archivos estarán disponibles en:

- `https://max9802.github.io/NinjaFlixConfig/manifest.json`
- `https://max9802.github.io/NinjaFlixConfig/catalog.json`

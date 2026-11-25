# Naive

Controla tus agentes de programación (Claude Code, Codex, Cursor, OpenCode, Devin, Grok, Hermes, Pi, Antigravity, Muse Code, fx) de forma local por defecto, con sincronización opcional entre varios dispositivos.

*[English](README.md) | [简体中文](README.zh-CN.md) | [한국어](README.ko.md) | [日本語](README.ja.md) | Español*

![App de escritorio de Naive](docs/media/readme/app-screenshot.jpg)

## App de escritorio

Descarga la última versión para tu plataforma desde [GitHub Releases](https://github.com/zeronsh/zeron/releases/latest):

- **macOS** (Apple silicon, macOS 13+) — `naive-<version>-macos-arm64.dmg`
- **Windows** — `naive-<version>-windows-x86_64-setup.exe`
- **Linux** — `naive-<version>-linux-<arch>.tar.gz` y luego ejecuta el `install.sh` que incluye

No necesitas cuenta ni conexión a internet; las sesiones se quedan en tu dispositivo. La app de escritorio está construida sobre [zgx](https://zgx.naive.sh) (Rust nativo con interfaz Luau de recarga en caliente, plugins, plantillas y temas) y se actualiza sola.

## Modo headless (CLI)

Para servidores y otras máquinas sin pantalla, como un VPS que mantiene los agentes en ejecución después de cerrar tu portátil. Solo Linux:

```bash
curl -fsSL https://naive.sh/install.sh | sh
naive status
```

El instalador arranca el motor como un servicio en segundo plano que sobrevive a los reinicios.

```bash
naive status      # modo local/sincronizado y estado del motor
naive update      # actualizar a la última versión
naive daemon start|stop|restart|status
```

## Sincronización entre dispositivos (opcional)

Inicia sesión para lanzar un agente en un dispositivo y seguirlo o controlarlo desde otro:

```bash
naive daemon stop
naive login        # o: naive logout para volver al modo solo local
naive daemon start
```

Los dispositivos con sesión iniciada en la misma cuenta pueden leer y escribir los archivos del espacio de trabajo de los demás, así que inicia sesión solo en dispositivos de confianza. Las sesiones locales existentes nunca se suben.

## Patrocinadores

Gracias a [The Context Company](https://www.thecontextcompany.com/) por patrocinar Naive. Tú también puedes ayudar a financiar el desarrollo de Naive [convirtiéndote en patrocinador en GitHub](https://github.com/sponsors/zeronsh).

---

¿Quieres contribuir o te interesa saber cómo funciona? [Pregúntale a DeepWiki](https://deepwiki.com/zeronsh/zeron), lee [ARCHITECTURE.md](ARCHITECTURE.md) o consulta [CONTRIBUTORS.md](CONTRIBUTORS.md) y [apps/zgx/README.md](apps/zgx/README.md).

Publicado bajo la [licencia MIT](LICENSE).

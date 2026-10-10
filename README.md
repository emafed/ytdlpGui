# ytdlpGui

Interfaccia web locale per yt-dlp: incolla un link, scegli formato e scarica.

## Avvio

1. Doppio clic su `start_app.bat`
2. Il browser si apre su http://localhost:8888

## Funzioni

- Download video o solo audio (mp3, m4a, aac, opus, wav, flac)
- Conversione audio compatibile Garmin (richiede ffmpeg nel PATH o in `_internal\`)
- Trasferimento automatico su dispositivo MTP (configura `transferDirectory` in `config.json`)
- Aggiornamento di yt-dlp integrato

## Cartelle

- `downloads/` - file scaricati
- `log/` - log dei task falliti e cronologia in `downloads.txt`
- `config.json` - configurazione locale

## Requisiti

- Windows con PowerShell 5.1
- `yt-dlp.exe` (incluso nel repo)
- ffmpeg opzionale, solo per la conversione audio

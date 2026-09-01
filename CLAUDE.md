# DABR — Docker Automated Backup with Rsync

## File
- `backup-paths.sh` — script unico
- `README.md` — documentazione

## Cosa copre — il buco che gli altri quattro lasciano
KDD fa i database (MySQL/PG/Mongo), DABS SQLite, DABV i volumi nominati, KCR esegue. **Nessuno copiava un path.** Bind mount, config, uploads, alberi di dati generati: non sono database, non sono volumi, e il git non ce l'ha perché sono generati o ignorati. È di solito la fetta più grossa, ed è quella che si scopre mancante il giorno che serve.

## Flusso
1. `BACKUP_PATHS` → ogni path diventa una dir nello snapshot, **nominata col suo basename**
2. Trova lo snapshot più recente → `rsync -aHAXx --link-dest` contro di lui
3. Verify per path: exit code rsync, snapshot non vuoto, trend size e trend numero file
4. Nel giorno `WEEKLY_DAY`: `cp -al` in `weekly/` (hardlink, costa ~zero)
5. Retention N-most-recent su daily, weekly e log
6. Email HTML + Telegram + ntfy, indipendenti

## Il punto: snapshot navigabili
Ogni snapshot è un albero normale in cui si entra con `cd`, non un archivio da estrarre. I file non cambiati sono hardlink: **misurato, il secondo giro costa 0 byte**.

## ⚠️ Requisito che decide tutto
La destinazione deve supportare gli **hardlink**: ext4/xfs/btrfs sì, exFAT/FAT32/SMB no — e senza hardlink ogni snapshot costa dimensione piena. Va verificato prima di scegliere il disco.

## ⚠️ I database ci sono ma NON sono affidabili
rsync su un DB vivo dà una copia incoerente (e per SQLite in WAL il recente sta in un file a parte, copiato in un altro istante). Sono inclusi solo per completezza del filesystem: **non si ripristina mai un DB da qui se esiste un dump**. Per quello ci sono KDD e DABS, che girano nella stessa Procedure.

## ⚠️ Niente `set -e`, ed è una scelta
Lo script conta errori e warning e li riporta. Con `errexit`, `((VAR++))` a variabile 0 ritorna exit 1 e **ucciderebbe il giro al primo warning, prima di ogni notifica**. È il difetto che aveva lo script originale da cui DABR nasce: `log_warn` era definito e mai chiamato, cioè una mina non ancora esplosa.

## Difetti trovati dal banco, non a lettura (S592)
- **Il dry-run creava una directory**: il `mkdir` dello snapshot stava prima del controllo `DRY_RUN`, e rsync `--dry-run` poi non ci scriveva. Restava una dir vuota che la retention contava come snapshot vero.
- **Basename in collisione**: due path con lo stesso `basename` si sovrascrivono dentro lo snapshot. Controllato all'avvio, con exit 1 — prima che scriva, non alle 3 di notte.

## Config (variabili top script)
`DRY_RUN`, `BACKUP_PATHS`, `DEST_MODE`, `DEST_BASE`, `REMOTE_*`, `SSH_KEY`, `DAILY_RETENTION`, `WEEKLY_RETENTION`, `WEEKLY_DAY`, `SIZE_DROP_WARN`, `FILE_DROP_WARN`, `EXCLUDE_PATTERNS`, `LOG_DIR`, SMTP/email, Telegram, ntfy.

## Local e remote dietro due funzioni
`dest_run()` esegue un comando dove stanno gli snapshot, `dest_target()` costruisce il target rsync. Il resto dello script **non ramifica mai** su `DEST_MODE`: aggiungere un caso nuovo si fa in un posto solo.

## Exit code
`exit 1` se `COUNT_ERR > 0`, altrimenti 0. KCR rileva il fallimento.

## Origine
Generalizzazione dello script `docker-serverdomotica.sh` del Sacerdote (repo `copie-mybunker`), che aveva già lo schema giusto — rsync + link-dest + daily/weekly — ma path e host cablati dentro, il report email che stampava la repr di una lista Python, e la mina di `set -e`.

## Ecosistema (5 tool)
KDD (MySQL/PG/Mongo) · DABS (SQLite) · DABV (volumi Docker) · **DABR** (path e file) · KCR (esegue i bash da Komodo)

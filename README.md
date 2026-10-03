# VPNBar

App nativa per macOS, scritta in Swift e SwiftUI, per controllare profili OpenVPN tramite Tunnelblick dalla barra dei menu. Include statistiche del traffico, strumenti DNS, domini locali, una CLI e condivisione di servizi locali tramite Cloudflare Tunnel.

## Funzioni

- Connessione, disconnessione e scelta dei server da un popover, senza icona nel Dock.
- Ricerca per paese, IP pubblico, ping, grafico del traffico e speed test tramite `networkQuality`.
- Preset DNS AdGuard, Quad9 e Cloudflare, oppure indirizzi personalizzati.
- Associazioni di domini `.test` a indirizzi IPv4 o IPv6 in `/etc/hosts`.
- CLI `vpnbar` e tre Comandi Rapidi per connettere, disconnettere e copiare l’IP.
- Condivisione di localhost tramite un link HTTPS temporaneo o un tunnel Cloudflare personale.

## Requisiti

- macOS 14 o successivo.
- Toolchain Swift 6 o successiva, fornita da una versione compatibile di Xcode o dei Command Line Tools.
- [Tunnelblick](https://tunnelblick.net/downloads.html) installato e configurato per le funzioni VPN.
- Profili OpenVPN e relative credenziali del proprio provider; l’interfaccia è predisposta per i paesi del catalogo Proton.
- Connessione Internet per scaricare `cloudflared` e usare i servizi online.

Non ci sono dipendenze Swift esterne. `cloudflared` è necessario solo per la condivisione di servizi locali.

## Setup e compilazione

### 1. Prepara gli strumenti e clona la repository

Se mancano i Command Line Tools, installali con `xcode-select --install`. Verifica che il compilatore selezionato sia Swift 6 o successivo:

```sh
swift --version
xcrun --find swift
```

Clona la repository:

```sh
git clone https://github.com/gabry848/VPNBar.git
cd VPNBar
```

### 2. Scarica il componente per le condivisioni

```sh
zsh scripts/fetch-cloudflared.sh
```

Lo script scarica la versione fissata nel progetto (`2026.9.3`) dagli asset ufficiali Cloudflare su GitHub, seleziona il binario per Apple Silicon o Intel e ne verifica il checksum SHA-256 prima dell’estrazione. Il risultato è `Resources/bin/cloudflared`, escluso da Git. Puoi saltare questo passaggio se non usi **Condividi**.

### 3. Compila e installa

```sh
zsh scripts/build.sh
```

Il bundle viene creato in `build/VPNBar.app`, con la CLI e gli helper inclusi. La compilazione usa `.build/` per le cache e firma l’app localmente con una firma ad hoc.

Sposta `build/VPNBar.app` in `/Applications` e aprila. L’app compare nella barra dei menu. L’installazione in `/Applications/VPNBar.app` è necessaria per i percorsi usati dai Comandi Rapidi inclusi.

Il bundle compilato localmente non è notarizzato. Lo script di compilazione non installa l’app e non modifica le impostazioni di rete.

### 4. Configura Tunnelblick e i profili VPN

1. Installa Tunnelblick dal sito ufficiale e avvialo.
2. Scarica i profili OpenVPN del tuo provider in una cartella privata. Per Proton, segui la [guida al download](https://protonvpn.com/support/vpn-config-download), selezionando la piattaforma macOS e il protocollo desiderato.
3. Prima dell’importazione, assegna a ogni file un nome nel formato `VPNBar-<PAESE>-<SERVER>.ovpn`, per esempio `VPNBar-NL-SERVER01.ovpn`.
4. Importa i file trascinandoli sull’icona di Tunnelblick e verifica che le configurazioni installate conservino quei nomi. Consulta la [guida di Tunnelblick](https://tunnelblick.net/cConfigT.html) per i dettagli.
5. Prova una connessione direttamente da Tunnelblick e inserisci le credenziali OpenVPN. Per Proton sono diverse dalla password dell’account: vedi la [guida Proton per Tunnelblick](https://protonvpn.com/support/mac-vpn-setup). Salvale nel Portachiavi tramite Tunnelblick.
6. Apri VPNBar e premi **Abilita controllo VPN**. Consenti l’automazione di Tunnelblick nella richiesta di macOS.

Se il consenso è stato negato, controlla **Impostazioni di Sistema → Privacy e sicurezza → Automazione**.

Il catalogo dell’app riconosce i codici `CA`, `CH`, `JP`, `MX`, `NL`, `NO`, `PL`, `RO`, `SG` e `US`. Un paese è disponibile soltanto se è installato almeno un profilo riconosciuto; la disponibilità dei server dipende dal provider e dal proprio piano. I profili con nomi diversi non vengono gestiti da VPNBar. Una configurazione estranea attiva in Tunnelblick impedisce il cambio server.

## CLI e Comandi Rapidi

Nel pannello aperto dall’icona terminale puoi creare il collegamento `~/.local/bin/vpnbar`. Se necessario, aggiungi `~/.local/bin` al `PATH` nel tuo `~/.zshrc`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

In alternativa usa direttamente `/Applications/VPNBar.app/Contents/Helpers/vpnbar`.

```sh
vpnbar --help
vpnbar status --json
vpnbar connect NL
vpnbar disconnect
vpnbar ip
vpnbar copy-ip
vpnbar dns adguard
vpnbar dns custom 1.1.1.1,1.0.0.1
vpnbar dns system
vpnbar domain add api.progetto.test 127.0.0.1
vpnbar domains --json
vpnbar domain remove api.progetto.test
vpnbar share http://localhost:3000
vpnbar share status
vpnbar share stop
```

La CLI comunica con la stessa app; il controllo VPN deve essere stato abilitato prima di connettersi. DNS e domini richiedono il consenso amministratore di macOS.

I file in `Resources/Shortcuts/` possono essere importati in Comandi Rapidi anche dal pannello dell’app: **Connetti VPN**, **Disconnetti VPN** e **Copia IP VPN**. Il comando di connessione usa `NL`, modificabile nel collegamento. Se richiesto, abilita l’esecuzione degli script nelle impostazioni avanzate di Comandi Rapidi.

## DNS, domini e condivisioni

**DNS:** scegli un preset e premi **Applica DNS**. Le modifiche interessano i servizi di rete abilitati e persistono anche dopo la chiusura dell’app. **DNS originali → Ripristina DNS originali**, oppure `vpnbar dns system`, ripristina i valori salvati. Il backup si trova in `/Library/Application Support/VPNBarNetwork/dns-backup.json`. I preset usano DNS tradizionale; il filtro DNS non elimina tutte le pubblicità.

**Domini:** associa un nome come `api.progetto.test` a `127.0.0.1`, poi usa, per esempio, `http://api.progetto.test:3000`. Le modifiche sono limitate al blocco gestito da VPNBar in `/etc/hosts` e persistono senza VPN. Wildcard, porte e certificati HTTPS non sono gestiti dalla funzione.

**Condividi:** avvia il tuo servizio locale, inserisci `http://localhost:3000` e premi **Condividi**. Il [Quick Tunnel](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/) genera un URL pubblico temporaneo senza account Cloudflare. Chi possiede il link può raggiungere il servizio: usalo per contenuti adatti alla condivisione. **Interrompi** o la chiusura di VPNBar termina il tunnel.

**Dominio personale:** richiede un tunnel Cloudflare già creato, il dominio instradato al tunnel, il suo UUID e il file credenziali JSON corrispondente. Inserisci questi dati in **Usa il mio dominio**. Conserva il file credenziali fuori dalla repository; VPNBar non crea account, tunnel o record DNS.

## Test e struttura

```sh
zsh scripts/test.sh
```

I test del core verificano validazione, gestione di `/etc/hosts`, transazioni DNS, rollback e protocollo di controllo. Usano un backend DNS simulato e non modificano la rete del Mac.

| Percorso | Contenuto |
| --- | --- |
| `Sources/VPNBar/` | App e interfaccia della barra dei menu |
| `Sources/VPNBarCore/` | Validazione, impostazioni e logica condivisa |
| `Sources/VPNBarCLI/` | Comando `vpnbar` |
| `Sources/VPNBarNetwork/` | Helper per DNS e domini locali |
| `Sources/VPNBarShareAgent/` | Supervisor delle condivisioni |
| `Resources/` | Metadati dell’app, Comandi Rapidi e licenza di cloudflared |
| `Tests/` | Test del core |
| `scripts/` | Download di cloudflared, compilazione e test |

## Limiti e dati locali

VPNBar si affida a Tunnelblick per il tunnel e le credenziali. Non implementa un kill switch; durante una disconnessione o un cambio server il traffico può usare la rete normale. Lo stato connesso non garantisce da solo l’assenza di perdite DNS o IPv6.

La verifica IP contatta `api.ipify.org`, il ping usa `1.1.1.1` e lo speed test genera traffico tramite `networkQuality`. Questi servizi vedono l’IP usato dalla connessione.

Le impostazioni dell’app, le richieste della CLI e le configurazioni temporanee delle condivisioni risiedono in `~/Library/Application Support/VPNBar/`. Se imposti `VPNBAR_DATA_DIR`, usa una directory privata fuori dalla repository.

## Repository GitHub

Il codice sorgente è pubblicato su [gabry848/VPNBar](https://github.com/gabry848/VPNBar). La repository include sorgenti, test, script e risorse necessarie alla compilazione. `.gitignore` esclude profili VPN, chiavi e certificati personali, credenziali, dati runtime, build, log, screenshot di verifica e stato locale degli editor e degli agenti. Il binario cloudflared viene scaricato durante il setup; la sua [licenza Apache-2.0](Resources/cloudflared-LICENSE.txt) è inclusa.

Mantieni profili e credenziali fuori dalla repository. Le esclusioni non riconoscono ogni possibile nome di un file privato e non rimuovono dati già presenti nella cronologia.

# Third-Party Sources

Questa cartella contiene sorgenti esterni inclusi localmente per rendere il progetto
autosufficiente durante analisi e patch compat.

## Included

- `updesk-server-1.1.15`
  - origine: `https://github.com/rustdesk/rustdesk-server.git`
  - tag usato: `1.1.15`
  - commit usato per la copia locale: `9bae9f2`
  - scopo:
    - riferimento sorgenti `hbbs/hbbr`
    - confronto protocollo relay/rendezvous
    - debug compat con client UpDesk/RustDesk `1.4.6`

Nota:
- il `Cargo.toml` upstream in questa snapshot riporta `version = "1.1.14"`, ma la copia e`
  stata presa dal tag git `1.1.15`.

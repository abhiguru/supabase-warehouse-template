# Operator printing integration

Printing is not ready to enable on the operator branch. The public discovery
capability defaults to `false`, and the main Edge router rejects print routes.
The authoritative [operator ledger](PRODUCTION_DEPENDENCIES.md#independent-operator-installation-work)
tracks the remaining software and physical acceptance. Starting CUPS or changing
a capability flag does not complete that work.

The repository retains the LQ-1310 ESC/P layouts and CUPS image. The isolated
`npm run test:cups` check covers container startup, administrator credential
requirements and spool preservation; it does not submit paper jobs or validate
printer transport. CUPS has no published host port. Its spool is a project-scoped
Docker volume, so independent instances cannot share queued documents merely
because they use the same source checkout. The core database/document backup
does not yet include that optional volume.

The intended pilot transports are Linux direct USB through CUPS, and a private
Windows USB printer queue shared to the Linux VM through Samba. Windows transport
requires implementation and physical verification before it is supported.

Before enabling printing, complete queue configuration, operator document
branding and bounded form alignment, authorized submission, durable job identity
and duplicate protection. Expose queued, failed, completed-as-reported and
unknown outcomes accurately. A disappeared job is not proof of physical output;
never automatically resubmit an uncertain job.

Then record physical LQ-1310 continuous-form tests for GRN, dispatch and invoice,
multiple slips/pages, disconnects, paper outages and unattended reboot. Keep
CUPS administration and backend service-role credentials private to the server.
The mobile app must submit under its own authorized user session.

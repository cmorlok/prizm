## REMOVED Requirements

### Requirement: User can empty trash
**Reason**: It names `DELETE /ciphers/purge`, which no server provides. The real
`POST /ciphers/purge` deletes the whole vault, active items and folders included, so following
this requirement would destroy data.
**Migration**: Empty Trash is now specified in the `empty-trash` capability: a bulk delete of
exactly the trashed items, and no `/purge` path is ever called.

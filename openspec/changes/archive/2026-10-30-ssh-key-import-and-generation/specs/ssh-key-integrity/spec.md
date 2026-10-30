# Spec Delta

## REMOVED Requirements

### Requirement: SSH keys cannot be created until Prizm can generate or import them
**Reason**: `fix-ssh-key-roundtrip` removed SSH key creation as an interim measure. Prizm can now generate and import keys, so creation returns (`ssh-key-creation`).
**Migration**: The New Item menu offers SSH Key again; see `ssh-key-creation`.

# Post-graphics cleanup checklist

Start these tasks after the graphics implementation is complete.

- [ ] Normalize computer identity fields across configuration, installation
  receipts and their readers. The installer currently writes aliases including
  `computerID` / `computerId` / `computer_id`, `coreID` / `coreId` / `core_id`,
  and `computerLabel` / `computer_label` / `label`. Choose a canonical naming
  convention, update producers and consumers together, and migrate existing
  installations through the supported installer and updater. Retain legacy
  input compatibility during migration and reject conflicting alias values.
  Verify fresh installation, existing-install updates, role registration,
  receipt validation, registry binding and startup before removing redundant
  persisted fields. Do not remove individual aliases during graphics work.

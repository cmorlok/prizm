# Release notes draft: attachments (for the maintainer)

Draft for the top of the release notes of the release that ships fix-attachment-transfer-flow,
fix-org-attachment-key and fix-attachment-file-format together. Plain text for users.

---

## Attachments: please convert files saved with earlier Prizm versions

**Who is affected:** everyone who attached files in Prizm 1.1.0 to 1.5.x.

**What was wrong:**

- These versions saved attachment files in their own layout. Other Bitwarden apps (browser
  extension, web vault, desktop, mobile and CLI) cannot open those files. Prizm could not open
  files that other Bitwarden apps attached either.
- On an organization item without its own item key, Prizm encrypted the files you attached with
  your personal key instead of the organization's key. Other members could not open them, and
  after the next sync they disappeared from the item in Prizm, although they still used storage.

**What this version does:**

- New attachments use the standard Bitwarden format and the right key, so every Bitwarden app can
  open them, and Prizm opens files from other Bitwarden apps.
- Prizm still opens your old files. They are marked **Prizm format**. Files on organization items
  that only you can open are shown again and marked **Only you can open this file**.

**What you should do:**

1. Sign in and let Prizm sync. If you have old files, Prizm tells you how many and offers
   **Convert All**.
2. Choose **Convert All**. Prizm converts one file at a time and shows its progress. You can
   cancel between files and convert the rest later. To convert a single file, open its item and
   choose **Convert** on the file.
3. When it is done, check the list of files that could not be converted, if there is one.

Converting uploads each file again in the standard format and then removes the old copy. The file
gets a new attachment ID; its name and contents stay the same. If you choose **Later**, Prizm asks
again after you next unlock.

**Good to know:**

- Converting needs a connection to your server and uses as much upload as the files are large.
- If the old copy could not be removed, the item shows both; delete the old one yourself.
- You can only convert files on items you are allowed to edit. On other items the server refuses,
  Prizm shows its message, and nothing changes. Ask someone who can edit the item to convert the
  file in Prizm.
- Until a file is converted, only Prizm can open it. Other members of an organization cannot open
  files marked **Only you can open this file** until you convert them.
- Tested with Vaultwarden 1.37.4. Bitwarden self-hosted and Bitwarden cloud were not tested.

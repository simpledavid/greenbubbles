# File Helper local knowledge library

This fork adds `greenbubbles-knowledge`, `GreenBubblesKnowledgeUI` and
`GreenBubblesHistoryUI` for embedding in a SwiftUI macOS app such as Tars.
The original `greenbubbles-history` executable continues to use the same history UI.

The knowledge library captures only user submissions to `filehelper`. It keeps
exact readable text, HTTP(S) links, original message JSON and independent copies
of downloaded attachments. It skips other conversations and system/recall notices.
Unsupported or truncated content retains its original decode state.

Configure the existing GreenBubbles CLI, WeChat database root, private passphrase
file and destination. The key is sent only on stdin and is never stored in the
knowledge library. The standalone default is
`~/Library/Application Support/GreenBubblesKnowledge`.

Storage uses a SQLite search index, `entries/<account-and-message-hash>/note.md`,
`source.json`, and verified attachment files. Directories are 0700 and files 0600;
the library itself is local plaintext. Viewing saved content requires neither a
running WeChat nor a model account.

Sync ingests up to 20 pages of 100 messages per run. Durable cursor queues keep
both new-message gaps and historical checkpoints, including after restart.
Incomplete shard coverage never advances a checkpoint. IDs include source
identity so multiple accounts remain distinct. Attachment retry is bounded to
100 items from the configured account; rotating attempts also reach older items.
Missing/expired/undecodable media keeps an explicit status and its source message.

Enable auto sync to check every 30 seconds while the view remains mounted in the
running app. UI search supports literal Chinese text and punctuation, categories,
pagination, copying, opening attachments and revealing Markdown files.

The CLI must be built or installed separately; its 0.10.0 raw JSON output is
requested explicitly for message and search pages. Initial WeChat key acquisition
remains the user's manual setup described in `PASSPHRASE_ACQUISITION.md`.

```sh
swift run greenbubbles-knowledge
# Synthetic UI preview, no real account access:
swift run greenbubbles-knowledge --demo --library /tmp/greenbubbles-knowledge-demo
swift test
```

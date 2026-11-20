# Neon

Neon is a native AI chat app for iPhone, iPad, and Mac. Use OpenRouter with a self-hosted Neon backend, or connect to Ollama on your Mac.

- Branch a conversation by editing an earlier prompt while keeping the original.
- Queue follow-up messages while a reply is running.
- Sync OpenRouter chats across devices and let replies finish in the background.

## Build from source

You’ll need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Neon runs on iOS 17 or later and macOS 14 or later.

```sh
brew install xcodegen
git clone https://github.com/zackbraksa/neon.git
cd neon
./script/build_and_run.sh
```

For iPhone or iPad development, run `xcodegen generate` and open `OpenChat.xcodeproj`. Select the **OpenChat** scheme and an iOS Simulator. For a physical device, use your own signing team and bundle identifier.

## Connect a model

**Ollama on Mac.** Start [Ollama](https://ollama.com/) with a model installed, then choose **Use Ollama on this Mac**. Chats stay on that Mac. Choose a local model for on-device processing.

**OpenRouter.** Follow the [backend setup guide](backend/README.md), then enter your OpenRouter API key in Neon. The app defaults to `http://localhost:8080`. To connect to a server from another device, set `NEON_BACKEND_URL` in [project.yml](project.yml) to your server’s HTTPS URL before generating the Xcode project. The Mac runner also accepts it as an environment variable.

The backend stores synced chat text and images and sends relevant content to OpenRouter and the model provider to generate replies. The backend encrypts your API key. Chat text and images are stored unencrypted in SQLite.

## License

[MIT](LICENSE)

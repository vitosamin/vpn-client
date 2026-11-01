/// The apps the product suggests for the VPN, taken from the owner's router setup: the services
/// that are throttled or blocked in Russia. Only the ones installed on the phone are selected.
abstract final class PopularApps {
  static const packages = [
    // video
    "com.google.android.youtube",
    "com.google.android.apps.youtube.music",
    "com.netflix.mediaclient",
    "com.zhiliaoapp.musically",
    "com.zhiliaoapp.musically.go",
    // messaging and social
    "org.telegram.messenger",
    "org.telegram.messenger.web",
    "org.thunderdog.challegram",
    "com.instagram.android",
    "com.facebook.katana",
    "com.facebook.orca",
    "com.whatsapp",
    "com.whatsapp.w4b",
    "com.discord",
    "com.twitter.android",
    "com.viber.voip",
    "com.snapchat.android",
    "com.reddit.frontpage",
    "com.pinterest",
    // music and AI
    "com.spotify.music",
    "com.openai.chatgpt",
    "com.google.android.apps.bard",
    "com.anthropic.claude",
  ];
}

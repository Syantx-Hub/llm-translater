import Foundation

/// Sample dialogue for caption previews, in every supported subtitle language, so the
/// preview shows real script shapes (stacked Burmese, CJK, Arabic) and a distinct original.
enum SampleCaptions {
    static let english = [
        "Where have you been all night?",
        "I was waiting for you at the station.",
        "Don't worry, my brother will drive us home.",
        "We have to leave before the rain starts.",
    ]

    static let translations: [String: [String]] = [
        "my": ["တစ်ညလုံး ဘယ်မှာရှိခဲ့လဲ။", "ဘူတာမှာ မင်းကို စောင့်နေခဲ့တာ။", "စိတ်မပူပါနဲ့၊ အစ်ကိုက အိမ်ကို လိုက်ပို့ပေးမယ်။", "မိုးမရွာခင် ထွက်သွားရမယ်။"],
        "ko": ["밤새 어디 있었어?", "역에서 너를 기다리고 있었어.", "걱정 마, 형이 집까지 데려다줄 거야.", "비 오기 전에 떠나야 해."],
        "ja": ["一晩中どこにいたの？", "駅で君を待っていたんだ。", "心配しないで、兄が家まで送ってくれるよ。", "雨が降る前に出なきゃ。"],
        "zh": ["你一整晚去哪儿了？", "我一直在车站等你。", "别担心，我哥哥会开车送我们回家。", "我们得在下雨前走。"],
        "th": ["เมื่อคืนเธอไปอยู่ที่ไหนมา", "ฉันรอเธออยู่ที่สถานี", "ไม่ต้องห่วง พี่ชายฉันจะขับรถไปส่งเราที่บ้าน", "เราต้องไปก่อนฝนตก"],
        "vi": ["Cả đêm qua cậu ở đâu vậy?", "Tớ đã đợi cậu ở nhà ga.", "Đừng lo, anh tớ sẽ chở chúng ta về nhà.", "Chúng ta phải đi trước khi trời mưa."],
        "id": ["Semalaman kamu ke mana?", "Aku menunggumu di stasiun.", "Jangan khawatir, kakakku akan mengantar kita pulang.", "Kita harus pergi sebelum hujan turun."],
        "ms": ["Sepanjang malam awak ke mana?", "Saya menunggu awak di stesen.", "Jangan risau, abang saya akan hantar kita pulang.", "Kita perlu pergi sebelum hujan turun."],
        "hi": ["तुम पूरी रात कहाँ थे?", "मैं स्टेशन पर तुम्हारा इंतज़ार कर रहा था।", "चिंता मत करो, मेरा भाई हमें घर छोड़ देगा।", "बारिश शुरू होने से पहले हमें निकलना होगा।"],
        "fr": ["Où étais-tu toute la nuit ?", "Je t'attendais à la gare.", "Ne t'inquiète pas, mon frère va nous ramener.", "On doit partir avant qu'il pleuve."],
        "es": ["¿Dónde estuviste toda la noche?", "Te estaba esperando en la estación.", "No te preocupes, mi hermano nos llevará a casa.", "Tenemos que irnos antes de que llueva."],
        "de": ["Wo warst du die ganze Nacht?", "Ich habe am Bahnhof auf dich gewartet.", "Keine Sorge, mein Bruder fährt uns nach Hause.", "Wir müssen los, bevor es regnet."],
        "pt": ["Onde você esteve a noite toda?", "Eu estava te esperando na estação.", "Não se preocupe, meu irmão vai nos levar para casa.", "Temos que sair antes que comece a chover."],
        "ru": ["Где ты был всю ночь?", "Я ждал тебя на вокзале.", "Не волнуйся, брат отвезёт нас домой.", "Нам нужно уйти до дождя."],
        "ar": ["أين كنت طوال الليل؟", "كنت أنتظرك في المحطة.", "لا تقلق، أخي سيوصلنا إلى البيت.", "علينا أن نغادر قبل أن يبدأ المطر."],
        "en": english,
    ]

    /// Four lines as they would appear in `language`, spoken in English (Korean when the
    /// subtitles themselves are English). Transcribe-only shows the spoken words.
    static func lines(language: String, translating: Bool) -> [SubtitleLine] {
        let spoken = language == "en" && translating ? translations["ko"]! : english
        let shown = translating ? translations[language] ?? english : spoken
        return zip(spoken, shown).map { SubtitleLine(original: $0, translation: $1) }
    }
}

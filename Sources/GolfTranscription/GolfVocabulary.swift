import Foundation

/// The closed vocabulary a golf round is narrated in — **in both languages**.
///
/// Golf's advantage as an ASR target is that almost everything that matters is
/// said in a few dozen words: fourteen clubs, nine scoring terms, a handful of
/// lies. Feeding them to the recognizer is what keeps "I'm hitting seven" from
/// coming back as "I'm hitting Kevin" — and since diarization was cut, a mangled
/// club or name is not a cosmetic error, it is a lost attribution.
///
/// **Two consumers, two jobs, and conflating them is the mistake.**
///
/// - ``all`` biases a *recognizer*, before any model sees a word. It is a list of
///   things that are likely to be said, so misheard audio resolves toward a real
///   golf word instead of a plausible non-golf one.
/// - ``synonyms`` is for the *model step*, and it exists because half the Korean
///   list is not a recognition problem at all. Whisper transcribes 고구마
///   perfectly, and 고구마 means *sweet potato*. The recognizer did its job; the
///   word simply means a hybrid to a golfer and nothing anywhere records that.
///   Words like 따블, 트, 유틸 and 오비 are the same shape.
///
/// Which is why `synonyms` is a **glossary the model reads, never a rewrite of
/// the log text**. Some of these are single syllables that occur constantly in
/// ordinary Korean — 따 and 트 are morphemes, not just golf slang — so a
/// mechanical substitution would corrupt sentences that had nothing to do with
/// scoring. A log is the observation stream and stays exactly as it was heard;
/// the glossary tells the model what the observation is likely to mean.
public enum GolfVocabulary {

    // MARK: - English

    public static let clubs = [
        "driver", "three wood", "four wood", "five wood", "seven wood",
        "one iron", "two iron", "three iron", "four iron", "five iron", "six iron",
        "seven iron", "eight iron", "nine iron",
        "hybrid", "three hybrid", "four hybrid", "five hybrid",
        "utility", "rescue",
        "pitching wedge", "gap wedge", "sand wedge", "lob wedge",
        "fifty two", "fifty six", "sixty", "putter", "wedge",
    ]

    /// Said far more often than the full club name — "I'm hitting seven".
    public static let clubShorthand = [
        "hitting seven", "hitting eight", "hitting nine", "hitting six",
        "hitting five", "hitting four", "hard eight", "easy seven", "smooth six",
    ]

    public static let scoring = [
        "birdie", "eagle", "albatross", "par", "bogey", "double bogey",
        "triple bogey", "quadruple bogey", "quintuple bogey", "quad",
        "double", "triple", "snowman", "ace", "hole in one",
        "up and down", "two putt", "three putt", "gimme", "concede", "conceded",
    ]

    public static let lies = [
        "fairway", "rough", "first cut", "bunker", "sand trap", "trap", "sand",
        "green", "fringe", "collar", "tee box", "cart path", "hazard",
        "penalty area", "out of bounds", "O B", "water", "pond", "creek",
        "lost ball", "provisional", "unplayable", "plugged", "buried", "divot",
    ]

    /// Turn order and the questions that resolve a hole — the utterances that
    /// carry attribution and score, which is the whole reason the microphone is on.
    public static let play = [
        "golf", "hole", "you're away", "I'm away", "still away", "your honour",
        "your honor", "away", "pick it up", "good good",
        "what'd you make", "what did you make", "what do you have",
        "how many", "net", "gross", "press", "closest to the pin",
        "front pin", "back pin", "middle pin", "front edge", "back edge",
        "carry", "lay up", "go for it", "in play", "safe", "short", "long",
        "left", "right", "pin high", "flag", "pin",
    ]

    /// Hole and score words in the numeric range a golfer actually says, cardinal
    /// and ordinal — a hole is "the seventh" as often as it is "hole seven".
    public static let numbers = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
        "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth",
        "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth",
    ]

    public static let english: [String] =
        clubs + clubShorthand + scoring + lies + play + numbers

    // MARK: - Korean

    /// The same round, said in Korean.
    ///
    /// **Not a translation of the English list.** A Korean foursome says 따블 and
    /// 고구마, which have no English counterpart, and does *not* say most of the
    /// English turn-order phrases. Several entries here are loanwords a
    /// multilingual model may render in either script (오비 / OB, 파 / par); that
    /// is the ``ScriptLocale`` problem, not this one, and both spellings are
    /// deliberately reachable through ``synonyms``.
    public enum Korean {

        public static let clubs = [
            "드라이버", "퍼터", "웨지", "아이언", "우드",
            "1번아이언", "2번아이언", "3번아이언", "4번아이언", "5번아이언",
            "6번아이언", "7번아이언", "8번아이언", "9번아이언",
            "3번우드", "4번우드", "5번우드",
            "하이브리드", "고구마", "유틸리티", "유틸",
            "피칭웨지", "샌드웨지", "갭웨지", "로브웨지",
        ]

        public static let scoring = [
            "파", "버디", "보기", "더블보기", "따블보기", "따블", "따",
            "트리플", "트리플보기", "트", "콰드루플보기", "퀸투플보기",
            "이글", "알바트로스", "홀인원", "컨시드", "오케이",
            "쓰리퍼트", "투퍼트", "원퍼트",
        ]

        public static let lies = [
            "그린", "페어웨이", "러프", "오비", "해저드", "벙커", "모래",
            "물", "연못", "워터해저드", "티박스", "프린지", "카트도로", "디봇",
        ]

        public static let play = [
            "골프", "홀", "타", "온", "핀", "깃대", "그린에지",
            "먼저", "치세요", "나이스샷", "굿샷",
        ]

        /// A hole is 번홀; a score is 타. Both are said with the number attached,
        /// so the compound is what the recognizer should expect to hear.
        public static let numbers: [String] =
            (1...18).map { "\($0)번홀" } + (1...9).map { "\($0)타" }

        public static let all: [String] = clubs + scoring + lies + play + numbers
    }

    // MARK: - Everything

    public static let all: [String] = english + Korean.all

    // MARK: - Glossary

    /// What a golfer means by a word the dictionary defines differently.
    ///
    /// **For the model step, not for the recognizer and not for rewriting text.**
    /// Every entry here is a word Whisper gets *right* and a reader gets wrong:
    /// 고구마 is a sweet potato everywhere except beside a golf bag, 따블 is not
    /// in a dictionary at all, and 트 on its own is a syllable. Handing the model
    /// a glossary lets it apply judgement in context, which is precisely what a
    /// `replacingOccurrences` pass cannot do — and the one that would quietly
    /// mangle a sentence about lunch.
    ///
    /// Keyed by what is *said*; the value is what it means, in the term the rest
    /// of the vocabulary uses.
    public static let synonyms: [String: String] = [
        // Korean scoring slang — contractions of the loanword.
        "따블": "더블보기 (double bogey)",
        "따블보기": "더블보기 (double bogey)",
        "따": "더블보기 (double bogey)",
        "트": "트리플보기 (triple bogey)",
        "트리플": "트리플보기 (triple bogey)",
        "콰드": "콰드루플보기 (quadruple bogey, 4 over par)",
        "콰드루플보기": "quadruple bogey, 4 over par",
        "퀸투플보기": "quintuple bogey, 5 over par",
        "오케이": "conceded putt (a gimme)",
        "컨시드": "conceded putt (a gimme)",
        // Korean club slang.
        "고구마": "하이브리드 (hybrid) — not the vegetable",
        "유틸": "유틸리티 (hybrid/utility club)",
        "유틸리티": "hybrid club",
        // Korean loanwords for a lie or a penalty.
        "오비": "OB, out of bounds",
        "해저드": "penalty area",
        "온": "on the green (\u{201C}투온\u{201D} = on in two)",
        "타": "strokes (\u{201C}5타\u{201D} = five strokes)",
        // English shorthand that is not a dictionary word either.
        "quad": "quadruple bogey, 4 over par",
        "snowman": "eight strokes on one hole",
        "good good": "both putts conceded",
        "gimme": "conceded putt, not holed out",
    ]

    /// The glossary as prompt text, sorted so the same round produces the same
    /// prompt twice — a prompt that reorders itself defeats caching and makes two
    /// runs incomparable.
    public static var glossaryLines: [String] {
        synonyms.keys.sorted().map { "- \($0) = \(synonyms[$0]!)" }
    }
}

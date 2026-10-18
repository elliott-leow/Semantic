import AppKit

// "party emoji", "smile emoji": a compact built-in table, one "emoji name|keywords" per line.
enum AppEmoji {
    struct Entry { let char: String; let name: String; let words: [String] }

    static let all: [Entry] = table.split(separator: "\n").compactMap { line in
        guard let sp = line.firstIndex(of: " ") else { return nil }
        let rest = line[line.index(after: sp)...].split(separator: "|", maxSplits: 1).map(String.init)
        guard let name = rest.first else { return nil }
        return Entry(char: String(line[..<sp]), name: name, words: nameTokens(name + " " + (rest.count > 1 ? rest[1] : "")))
    }

    static func query(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\\b(emojis?|emoticons?|smiley for|icon for|an?|the|for|copy|insert|find|search)\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // every query word starts a name or keyword; whole-word name matches first
    static func search(_ q: String, limit: Int = 8) -> [Entry] {
        let words = nameTokens(q)
        guard !words.isEmpty else { return [] }
        let found = all.enumerated().compactMap { i, e -> (Int, Int)? in
            guard words.allSatisfy({ w in e.words.contains { $0.hasPrefix(w) } }) else { return nil }
            let names = nameTokens(e.name)
            return (i, words.filter { names.contains($0) }.count * 2 + words.filter { e.words.contains($0) }.count)
        }
        return found.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map { all[$0.0] }
    }

    static func hits(_ text: String) -> [Hit] {
        search(query(text)).map { e in
            Hit(title: "\(e.char)  \(e.name)", subtitle: "Emoji · ↩ copy", icon: .symbol("face.smiling"), tag: "Emoji", key: "emoji:" + e.char) { _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(e.char, forType: .string)
                Toast.show("Copied \(e.char)")
            }
        }
    }

    private static let table = """
😀 grinning face|smile happy
😃 grinning face with big eyes|smile happy
😄 grinning face with smiling eyes|smile happy laugh
😁 beaming face|grin smile
😆 grinning squinting face|laugh
😅 grinning face with sweat|nervous relief
🤣 rolling on the floor laughing|rofl lol
😂 face with tears of joy|laugh lol cry
🙂 slightly smiling face|smile
🙃 upside-down face|silly sarcasm
😉 winking face|wink
😊 smiling face with smiling eyes|blush happy
😇 smiling face with halo|angel innocent
🥰 smiling face with hearts|love adore
😍 heart eyes|love crush
🤩 star-struck|wow excited
😘 face blowing a kiss|kiss love
😗 kissing face|kiss
😋 face savoring food|yum delicious tongue
😛 face with tongue|tongue playful
😜 winking face with tongue|crazy playful
🤪 zany face|crazy goofy
😝 squinting face with tongue|tongue
🤑 money-mouth face|rich money
🤗 hugging face|hug
🤭 face with hand over mouth|oops giggle
🤫 shushing face|quiet secret shh
🤔 thinking face|think hmm
🤐 zipper-mouth face|secret quiet
🤨 face with raised eyebrow|skeptical suspicious
😐 neutral face|meh
😑 expressionless face|blank
😶 face without mouth|speechless
😏 smirking face|smirk
😒 unamused face|annoyed meh
🙄 face with rolling eyes|eyeroll annoyed
😬 grimacing face|awkward grimace
😌 relieved face|calm relief
😔 pensive face|sad
😪 sleepy face|tired
🤤 drooling face|drool
😴 sleeping face|sleep tired zzz
😷 face with medical mask|sick mask
🤒 face with thermometer|sick ill
🤕 face with head-bandage|hurt injured
🤢 nauseated face|sick gross
🤮 face vomiting|vomit sick gross
🤧 sneezing face|sneeze sick
🥵 hot face|heat sweating
🥶 cold face|freezing
🥴 woozy face|drunk dizzy
😵 dizzy face|dizzy dead
🤯 exploding head|mind blown shocked
🤠 cowboy hat face|cowboy
🥳 partying face|party celebrate birthday
😎 smiling face with sunglasses|cool sunglasses
🤓 nerd face|nerd geek
🧐 face with monocle|inspect fancy
😕 confused face|confused
😟 worried face|worried
🙁 slightly frowning face|frown sad
😮 face with open mouth|surprised wow
😯 hushed face|surprised
😲 astonished face|shocked
😳 flushed face|embarrassed blush
🥺 pleading face|puppy eyes please
😦 frowning face with open mouth|shocked
😧 anguished face|anguish
😨 fearful face|scared fear
😰 anxious face with sweat|anxious nervous
😥 sad but relieved face|sad
😢 crying face|cry sad tear
😭 loudly crying face|sob cry sad
😱 face screaming in fear|scream scared
😖 confounded face|frustrated
😣 persevering face|struggle
😞 disappointed face|sad disappointed
😓 downcast face with sweat|sweat
😩 weary face|tired weary
😫 tired face|exhausted
🥱 yawning face|yawn bored tired
😤 face with steam from nose|frustrated triumph
😡 pouting face|angry mad rage
😠 angry face|angry mad
🤬 face with symbols on mouth|swear curse angry
😈 smiling face with horns|devil evil
👿 angry face with horns|devil imp
💀 skull|dead death
☠️ skull and crossbones|danger poison pirate
💩 pile of poo|poop
🤡 clown face|clown
👻 ghost|halloween spooky
👽 alien|ufo space
🤖 robot|bot
😺 grinning cat|cat
😹 cat with tears of joy|cat laugh
😻 smiling cat with heart-eyes|cat love
🙈 see-no-evil monkey|monkey shy
🙉 hear-no-evil monkey|monkey
🙊 speak-no-evil monkey|monkey oops
💋 kiss mark|lips kiss
💌 love letter|letter love
💘 heart with arrow|love cupid
💝 heart with ribbon|gift love
💖 sparkling heart|love sparkle
💗 growing heart|love
💓 beating heart|love heartbeat
💞 revolving hearts|love
💕 two hearts|love
💔 broken heart|heartbreak sad
❤️ red heart|love heart
🧡 orange heart|heart
💛 yellow heart|heart
💚 green heart|heart
💙 blue heart|heart
💜 purple heart|heart
🖤 black heart|heart
🤍 white heart|heart
🤎 brown heart|heart
💯 hundred points|100 perfect score
💢 anger symbol|angry
💥 collision|boom explosion
💫 dizzy|star
💦 sweat droplets|water splash
💨 dashing away|wind fast
💬 speech balloon|chat message
💭 thought balloon|think
💤 zzz|sleep
👋 waving hand|wave hello bye hi
🤚 raised back of hand|hand
✋ raised hand|hand stop high five
🖖 vulcan salute|spock
👌 ok hand|ok okay perfect
🤌 pinched fingers|italian
✌️ victory hand|peace
🤞 crossed fingers|luck hope
🤟 love-you gesture|love
🤘 sign of the horns|rock metal
🤙 call me hand|call shaka
👈 backhand index pointing left|left point
👉 backhand index pointing right|right point
👆 backhand index pointing up|up point
👇 backhand index pointing down|down point
☝️ index pointing up|up point
👍 thumbs up|like yes approve good
👎 thumbs down|dislike no bad
✊ raised fist|fist power
👊 oncoming fist|punch fist bump
👏 clapping hands|clap applause bravo
🙌 raising hands|hooray celebrate praise
👐 open hands|hands
🤲 palms up together|pray
🤝 handshake|deal agreement
🙏 folded hands|pray please thanks
✍️ writing hand|write
💅 nail polish|nails
💪 flexed biceps|strong muscle flex
🧠 brain|smart think
👀 eyes|look see watching
👁️ eye|look
👅 tongue|tongue
👄 mouth|lips
👶 baby|baby child
🧒 child|kid
👦 boy|boy
👧 girl|girl
🧑 person|person adult
👨 man|man
👩 woman|woman
🧓 older person|old elderly
👴 old man|grandpa
👵 old woman|grandma
🙅 person gesturing no|no stop
🙆 person gesturing ok|ok
💁 person tipping hand|info sassy
🙋 person raising hand|hand question
🤦 person facepalming|facepalm
🤷 person shrugging|shrug dunno whatever
👮 police officer|police cop
💂 guard|guard
👷 construction worker|construction builder
🤴 prince|prince royal
👸 princess|princess royal
👰 person with veil|bride wedding
🤰 pregnant woman|pregnant
🎅 santa claus|christmas santa
🦸 superhero|hero
🧙 mage|wizard magic
🧛 vampire|vampire halloween
🧟 zombie|zombie halloween
💃 woman dancing|dance party
🕺 man dancing|dance party
🏃 person running|run running
🚶 person walking|walk
🧘 person in lotus position|yoga meditate
🏋️ person lifting weights|gym weights workout
🚴 person biking|bike cycling
🏊 person swimming|swim
⚽ soccer ball|football soccer sport
🏀 basketball|sport
🏈 american football|football sport
⚾ baseball|sport
🎾 tennis|sport
🏐 volleyball|sport
🏓 ping pong|table tennis
🏆 trophy|win winner award
🥇 1st place medal|gold first winner
🥈 2nd place medal|silver second
🥉 3rd place medal|bronze third
🎮 video game|game controller gaming
🎲 game die|dice
🎯 direct hit|target bullseye
🎉 party popper|party celebrate tada congratulations
🎊 confetti ball|party celebrate
🎈 balloon|party birthday
🎂 birthday cake|birthday cake
🎁 wrapped gift|present gift birthday
🎄 christmas tree|christmas
🎃 jack-o-lantern|halloween pumpkin
🎆 fireworks|celebrate new year
✨ sparkles|sparkle shiny magic new
⭐ star|star favorite
🌟 glowing star|star shine
🔥 fire|hot lit flame
⚡ high voltage|lightning electric zap
☀️ sun|sunny weather
🌤️ sun behind small cloud|weather
☁️ cloud|weather cloudy
🌧️ cloud with rain|rain weather
⛈️ cloud with lightning and rain|storm thunder
❄️ snowflake|snow cold winter
☃️ snowman|snow winter
🌈 rainbow|rainbow pride
☔ umbrella with rain drops|rain umbrella
🌊 water wave|wave ocean sea
🌙 crescent moon|moon night
🌍 globe showing europe-africa|earth world
🌎 globe showing americas|earth world
🌏 globe showing asia-australia|earth world
🪐 ringed planet|saturn space
🌸 cherry blossom|flower spring
🌹 rose|flower love
🌻 sunflower|flower
🌷 tulip|flower
🌱 seedling|plant grow
🌲 evergreen tree|tree
🌴 palm tree|tree beach tropical
🌵 cactus|desert plant
🍀 four leaf clover|luck lucky
🍁 maple leaf|autumn fall canada
🍂 fallen leaf|autumn fall
🐶 dog face|dog puppy
🐱 cat face|cat kitten
🐭 mouse face|mouse
🐹 hamster|hamster
🐰 rabbit face|bunny rabbit
🦊 fox|fox
🐻 bear|bear
🐼 panda|panda
🐨 koala|koala
🐯 tiger face|tiger
🦁 lion|lion
🐮 cow face|cow
🐷 pig face|pig
🐸 frog|frog
🐵 monkey face|monkey
🐔 chicken|chicken
🐧 penguin|penguin
🐦 bird|bird
🦆 duck|duck
🦉 owl|owl
🦄 unicorn|unicorn magic
🐝 honeybee|bee
🦋 butterfly|butterfly
🐢 turtle|turtle slow
🐍 snake|snake
🐙 octopus|octopus
🐬 dolphin|dolphin
🐳 spouting whale|whale
🦈 shark|shark
🐘 elephant|elephant
🦒 giraffe|giraffe
🐎 horse|horse
🐑 ewe|sheep
🐐 goat|goat
🦀 crab|crab
🍎 red apple|apple fruit
🍊 tangerine|orange fruit
🍋 lemon|lemon fruit
🍌 banana|banana fruit
🍉 watermelon|fruit summer
🍇 grapes|grapes fruit
🍓 strawberry|fruit berry
🍑 peach|peach fruit
🍒 cherries|cherry fruit
🥑 avocado|avocado
🍅 tomato|tomato
🥕 carrot|carrot vegetable
🌽 ear of corn|corn
🌶️ hot pepper|chili spicy
🥦 broccoli|vegetable
🍞 bread|bread toast
🧀 cheese wedge|cheese
🍳 cooking|egg breakfast
🥞 pancakes|breakfast
🥓 bacon|bacon breakfast
🍔 hamburger|burger food
🍟 french fries|fries chips
🍕 pizza|pizza food
🌭 hot dog|hotdog
🌮 taco|taco mexican
🌯 burrito|burrito
🥗 green salad|salad healthy
🍝 spaghetti|pasta
🍜 steaming bowl|ramen noodles
🍣 sushi|sushi japanese
🍱 bento box|bento japanese
🍦 soft ice cream|ice cream dessert
🍩 doughnut|donut
🍪 cookie|cookie
🍰 shortcake|cake dessert
🧁 cupcake|cupcake
🍫 chocolate bar|chocolate
🍬 candy|sweet
🍿 popcorn|movie snack
☕ hot beverage|coffee tea
🍵 teacup without handle|tea matcha
🧋 bubble tea|boba tea
🍺 beer mug|beer drink
🍻 clinking beer mugs|cheers beer
🍷 wine glass|wine drink
🥂 clinking glasses|cheers champagne toast
🍸 cocktail glass|cocktail martini
🥤 cup with straw|soda drink
🚗 automobile|car drive
🚕 taxi|taxi cab
🚌 bus|bus
🚑 ambulance|ambulance emergency
🚓 police car|police
🚲 bicycle|bike
🛵 motor scooter|scooter
🚂 locomotive|train
🚆 train|train
✈️ airplane|plane flight travel
🚀 rocket|launch ship space
🛸 flying saucer|ufo
🚢 ship|boat cruise
⛵ sailboat|boat
⚓ anchor|anchor
🏠 house|home
🏢 office building|office work
🏥 hospital|hospital
🏫 school|school
🏰 castle|castle
🗽 statue of liberty|new york
🗼 tokyo tower|tokyo
🏖️ beach with umbrella|beach vacation
🏔️ snow-capped mountain|mountain
⛺ tent|camping
⌚ watch|watch time
📱 mobile phone|phone iphone
💻 laptop|computer mac
⌨️ keyboard|keyboard
🖥️ desktop computer|computer
🖨️ printer|printer
🖱️ computer mouse|mouse
💾 floppy disk|save disk
💿 optical disk|cd
📷 camera|camera photo
🎥 movie camera|film video
📺 television|tv
📻 radio|radio
🎙️ studio microphone|mic podcast
🎧 headphone|headphones music
🎵 musical note|music note
🎶 musical notes|music song
🎸 guitar|guitar music
🎹 musical keyboard|piano
🥁 drum|drums
🎤 microphone|karaoke sing
🔋 battery|battery
🔌 electric plug|plug power
💡 light bulb|idea bulb
🔦 flashlight|torch
🕯️ candle|candle
💰 money bag|money rich
💵 dollar banknote|money cash dollar
💳 credit card|card payment
💎 gem stone|diamond jewel
⚖️ balance scale|justice law
🔧 wrench|tool fix
🔨 hammer|tool build
🛠️ hammer and wrench|tools build fix
⚙️ gear|settings cog
🔩 nut and bolt|bolt
🧲 magnet|magnet
🧪 test tube|science lab
🔬 microscope|science
🔭 telescope|astronomy
💊 pill|medicine drug
💉 syringe|vaccine shot
🩺 stethoscope|doctor
🚪 door|door
🛏️ bed|bed sleep
🛋️ couch and lamp|sofa
🚽 toilet|toilet bathroom
🚿 shower|shower
🛒 shopping cart|shopping
🔑 key|key password
🔒 locked|lock secure
🔓 unlocked|unlock
🔔 bell|notification bell
🔕 bell with slash|mute silent
📢 loudspeaker|announcement
📣 megaphone|announce cheer
⏰ alarm clock|alarm time wake
⏳ hourglass not done|wait time
📅 calendar|calendar date
📆 tear-off calendar|calendar
🗓️ spiral calendar|calendar schedule
📈 chart increasing|chart growth up stocks
📉 chart decreasing|chart down loss
📊 bar chart|chart stats
📋 clipboard|clipboard list
📌 pushpin|pin
📎 paperclip|attachment clip
✂️ scissors|cut
📝 memo|note write
✏️ pencil|pencil edit
🖊️ pen|pen
📁 file folder|folder
📂 open file folder|folder
📄 page facing up|document page
📃 page with curl|document
📚 books|books study library
📖 open book|book read
🔖 bookmark|bookmark
📦 package|box package shipping
✉️ envelope|email mail letter
📧 e-mail|email
📨 incoming envelope|mail
📬 open mailbox with raised flag|mail
🗑️ wastebasket|trash bin delete
🔍 magnifying glass tilted left|search find
🔗 link|link url
🧭 compass|direction
🗺️ world map|map
🎨 artist palette|art paint
🧩 puzzle piece|puzzle
♻️ recycling symbol|recycle
✅ check mark button|done yes check complete
☑️ check box with check|check
✔️ check mark|check done
❌ cross mark|no wrong x cancel
❎ cross mark button|no
➕ plus|plus add
➖ minus|minus
➗ divide|divide
❓ red question mark|question
❗ red exclamation mark|exclamation important
⚠️ warning|warning caution alert
🚫 prohibited|forbidden no
⛔ no entry|stop forbidden
🛑 stop sign|stop
🔴 red circle|red dot
🟠 orange circle|orange dot
🟡 yellow circle|yellow dot
🟢 green circle|green dot
🔵 blue circle|blue dot
🟣 purple circle|purple dot
⚫ black circle|black dot
⚪ white circle|white dot
⬆️ up arrow|up arrow
⬇️ down arrow|down arrow
⬅️ left arrow|left arrow
➡️ right arrow|right arrow
🔄 counterclockwise arrows button|refresh sync reload
🔁 repeat button|repeat loop
▶️ play button|play
⏸️ pause button|pause
⏹️ stop button|stop
⏭️ next track button|next skip
🆗 ok button|ok
🆕 new button|new
🆓 free button|free
🆒 cool button|cool
©️ copyright|copyright
®️ registered|registered trademark
™️ trade mark|trademark tm
#️⃣ keycap number sign|hash
🏁 chequered flag|finish race
🚩 triangular flag|flag red
🏳️ white flag|surrender
🏴 black flag|flag
🏳️‍🌈 rainbow flag|pride lgbt
🇺🇸 flag united states|usa america us
🇬🇧 flag united kingdom|uk britain england
🇸🇬 flag singapore|singapore
🇯🇵 flag japan|japan
🇨🇳 flag china|china
🇰🇷 flag south korea|korea
🇮🇳 flag india|india
🇫🇷 flag france|france
🇩🇪 flag germany|germany
🇮🇹 flag italy|italy
🇪🇸 flag spain|spain
🇨🇦 flag canada|canada
🇦🇺 flag australia|australia
🇧🇷 flag brazil|brazil
🇲🇽 flag mexico|mexico
"""
}

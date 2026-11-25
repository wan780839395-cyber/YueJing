import Foundation

/// A finite, authored side scene about a disputed recollection. Keywords choose a response,
/// not the meaning or success of arbitrary free text. No book handle, model or global state.
enum StoryTurnProse {
    private struct Beat {
        let response: String
        let consequence: String

        init(_ response: String, _ consequence: String) {
            self.response = response
            self.consequence = consequence
        }
    }

    private static func fragment(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    private static func beats(for action: String) -> (Beat, Beat) {
        if ["问", "说", "谈", "打听", "询", "喊"].contains(where: action.contains) {
            return (
                Beat("最先接话的人脱口说了一个‘都’字，随即住了口。你没有替他把半截话补齐。他看向身边那个一直不肯开口的人，像是第一次想到，两个人站得这么近，也未必看见同一件事。再开口时，他把那句很响亮的话拆成了两句很轻的话：一句是自己记得的，一句是后来才听见的。这两句话从前总挨在一起，如今中间有了一道缝。", "他答应只为亲眼见到的那一半作证"),
                Beat("这一次没有人抢着作答。有个人反倒把方才那句话原样问了回来，只换掉了一个字。原先听来像指责的地方，这么一换，竟成了求证。旁边的人试着也说了一遍，说到同一处却用了另一个字。两个人互相望着，一时都想不起最早听见的是哪一种说法。你听见一声短促的笑；那不是嘲弄，是有人终于可以承认自己记不清了。", "两种说法被分别留下，不再混成一句话"))
        }
        if ["看", "察", "查", "听", "找", "等", "辨", "搜"].contains(where: action.contains) {
            return (
                Beat("那阵窸窣声又响了一次。这回有了准备，你发现先动的不是刚刚说话的那个人，而是紧挨着他的一只手。每逢叙述到了同一个地方，指头就轻轻碰一下衣料；话声便在那里转了弯。也许只是个习惯。你耐着性子等到第三次，旁边终于有人也循声低下头去。原本只有你留意的细响，从这一刻起，多了一个可以相互核对的见证。", "又有一个人听出了停顿前的轻响"),
                Beat("近处的人都在看说话者的脸，你却看见一双脚悄悄转了方向。脚尖没有朝向声音，反倒朝着声音刚刚停过的地方。你挪开视线，等了一息再望过去，那人还站在原地，像在替谁留一个位置。等人群稍稍散开，空处恰好容得下一个人。先前显得十分肯定的那句‘没有别人’，现在不能再当成不必查问的事了。", "众人之间那个空位有了待查的来由"))
        }
        if ["走", "去", "离开", "跑", "跟", "追", "退", "绕"].contains(where: action.contains) {
            return (
                Beat("脚下换了一个位置，方才听得分明的话便少了一截尾音。有人在你背后继续说，隔着几个人，传到这里时竟像说了相反的意思。你回身望过去，那些面孔并没有故意作假的神情；只是每个人都拾起了离自己最近的半句。有个人试着沿你来时的方向走回去。等他再转过身，原本要替大家作保的话已收了回去。", "来路上多了一处能复核声音远近的位置"),
                Beat("身边让开了一道窄缝，却没有人催你赶紧过去。走在最外侧的人先回过头来：从他这里望过去，里面的人只剩肩背，谁先开口根本看不清。他把手抬到半空，朝两个方向各比了一下，像在分辨两条本来重合的线。后面跟上来的人也停在同一处，把刚才还言之凿凿的先后次序轻轻倒了过来。", "最外侧的见证人收回了对先后次序的保证"))
        }
        // An unrecognised action is still the player's action; do not replace it with a guessed one.
        return (
            Beat("出乎意料的是，最先有所回应的不是一直站在当中的人。边上有个人松开紧握的手，掌心里是几道很深的指甲印。他原来一直在等别人先表态，好决定该不该把自己知道的一点说出来。如今大家的注意不再都落在他脸上，他倒有了余裕，慢慢伸出两根手指。只这么一个小小的比画，就让原先连在一起的两件事分出了先后。", "那人愿意把两件事分开讲了"),
            Beat("旁边一声没响的那个人终于抬起眼来。他显然预备过一套应对别人的办法，却没预备过眼下这一刻。那套熟练的说辞在他舌尖打了个转，出来只剩一句很平常的话：可不可以从头听他讲一遍？这话不是向众人说的。他的声音很小，小到刚好只够你听见；是否把这件事变成大家的事，眼下还由得你选。", "你得到了单独听一次讲述的机会"))
    }

    // Pick a physical detail only from this session's opening. The response around it is fiction.
    private static func foothold(in opening: String) -> String {
        if opening.contains("门") { return "门里门外的人听见的不是同一回事。隔着一道门槛，里面的人记得声音，外面的人却只记得先后走过的几双脚。" }
        if opening.contains("雨") { return "雨把轻些的声音都遮去了。有人记得嘴唇动过，有人记得确实听见过一句话，两个人说的可能根本不是同一刻。" }
        if opening.contains("信封") || opening.contains("信纸") { return "提到那封信时，有人先看自己的手，有人先去看别人的脸。记得纸上写过什么，跟记得是谁递来的，本是两回事。" }
        if opening.contains("钟声") { return "钟声倒是人人都记得，只是谁也不肯第一个说出那是第几响。若把两声之间的空隙错算进去，前后的话就会换个次序。" }
        return "身旁有人也想讲起那一刻，讲到要紧处却含混过去。听的人没有追究，仿佛只要故事说得够顺，就不会有人回头看它漏掉了什么。"
    }

    static func compose(_ context: StoryTurnContext, action: String, sequence: Int,
                        previous: String?) -> (narration: String, consequence: String) {
        let source = context.opening.split(whereSeparator: { $0.isNewline }).first(where: { $0.count >= 6 })
        let anchor = fragment(source.map { String($0) } ?? context.opening, 32)
        let name = fragment(context.roleName, 16)
        let role = context.roleKind == .canon ? "你应着\(name)这个名字" : "你用\(name)这个新名字在此立足"
        let premise = context.premise.isEmpty ? "并没有急着说明来意" : "仍记着自己的来意：『\(fragment(context.premise, 22))』"
        let lead: String
        let thread: String
        if let previous {
            lead = "刚才那阵议论低了下去。\(role)，\(premise)。原先只顾讲述的人也侧过身来，试着从你的位置看一眼。你记起的仍是开头的「\(anchor)」，只是方才旁人的话太密，差点把记得的东西也一并盖了过去。"
            thread = "事情却没有从头再来。\(previous)。这点变化已经落到了实处：方才还能随口带过的地方，现在有人会停下来等，等那个真正知道内情的人自己出声。少掉的半句话让沉默长了几息，也替你的下一步腾出了地方。"
        } else {
            lead = "「\(anchor)」——记忆回到开篇这一处，再往前，就是你自己的路了。\(role)，\(premise)。\(foothold(in: context.opening))"
            thread = "有两个人几乎同时点头，一个是听懂了，另一个却慢了半拍，看见前一个人点头才跟着动。若不是正好站在这里，这点参差便会悄悄过去。没有人把疑问说破，而你还来得及决定，是让这段话照旧往下讲，还是给它一个不同的去处。"
        }
        let choice = sequence.isMultiple(of: 2)
            ? "这回，你选择「\(fragment(action, 30))」。一个原本打算离开的人停住了脚，像是要把这一刻看个清楚，免得日后又得靠别人转述。有人想开口拦他，话到嘴边却改了主意。多一个肯留下来的人，原也未必是件坏事。"
            : "你拿定的主意是「\(fragment(action, 30))」。起初大家仍照原来的节奏呼吸，一双眼睛看着另一双眼睛；等到该有人接话的那一刻过去，最靠近你的那个人才意识到，事情并不会自行回到方才的模样。"
        let (first, second) = beats(for: action)
        let beat: Beat
        if previous == first.consequence { beat = second }
        else if previous == second.consequence { beat = first }
        else { beat = sequence.isMultiple(of: 2) ? second : first }
        let close = "\(beat.consequence)。变化不大，还不足以让谁就此相信另一个人。可是当先前那句话又被提起时，你已经有了一件可以拿来比对的实事，不必再只凭声音的轻重猜测。余下的疑处仍在，你要不要向前再走一步，没人能替你应下。"
        let paragraphs = ["【离线演绎 · 非原文】", lead, thread, choice, beat.response, close]
        return (paragraphs.joined(separator: "\n\n"), beat.consequence)
    }
}

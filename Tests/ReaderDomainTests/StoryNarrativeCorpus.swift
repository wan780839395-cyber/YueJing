import Foundation
import Testing
@testable import ReaderDomain

// Original scenes and independent labels frozen before the architecture comparison.
// 'offered' is a scripted empty, sound, or hostile model sidecar, NOT an LLM measurement.
private struct Scene {
    let id: String, text: String
    let gold: [StoryMemoryFact], offered: [StoryMemoryFact]
}
func measureNarrativeCorpus() throws {
    typealias F = StoryMemoryFact
    func k(_ subject:String, _ value:String, _ line:String) -> F { .init(kind:"knowledge",subject:subject,value:value,evidence:line) }
    func p(_ subject:String, _ value:String, _ line:String) -> F { .init(kind:"promise",subject:subject,value:value,evidence:line) }
    let k1="阿宁知道钥匙在桌上。", f1=k("阿宁｜钥匙｜在｜桌上","已知",k1)
    let k2="只有许棠读过夹层里的落款。", f2=k("许棠｜读过夹层里的落款","已知",k2)
    let k3="陶师傅从抄件上认出了自己的字。", f3=k("陶师傅｜抄件上是自己的字","已知",k3)
    let k4="掌柜只听见门闩响，并没有看见进来的人。", f4=k("掌柜｜看清来客身份","已知",k4)
    let k5="“船已经沉了。”伙计这么说，没有人去河边看过。", f5=k("伙计｜船已沉没","已知",k5)
    let k6="如果岑婶听见隔壁的谈话，她就会知道船期改了。", f6=k("岑婶｜船期已改","已知",k6)
    let p1="我答应阿宁明日在南门会面。", a1=p("我｜阿宁｜明日｜南门｜会面","已约定",p1)
    let p2="施砚向摆渡人许诺，封河之前替他送完最后一袋盐。", a2=p("施砚｜摆渡人｜封河之前｜送完最后一袋盐","已约定",p2)
    let p3="守桥人履行了与裁缝天亮时交换收据的约定。", a3=p("守桥人｜裁缝｜天亮时｜交换收据","已兑现",p3)
    let p4="雪已经盖过了脚印。迟禾终究违背了把药送到渡口的承诺。", a4=p("迟禾｜把药送到渡口","已失约","迟禾终究违背了把药送到渡口的承诺。")
    let p5="船夫抬了抬手，像是要答应，最后只替她拂去袖上的水。", a5=p("船夫｜替她过河","已约定",p5)
    let p6="三更过去。她仍坐在茶棚里；谁也没说他们约的是今晚。", a6=p("她｜今晚｜会面","已失约",p6)
    let scenes=[Scene(id:"K1",text:k1,gold:[f1],offered:[f1]),Scene(id:"K2",text:k2,gold:[f2],offered:[f2]),Scene(id:"K3",text:k3,gold:[f3],offered:[]),Scene(id:"K4",text:k4,gold:[],offered:[f4]),Scene(id:"K5",text:k5,gold:[],offered:[f5]),Scene(id:"K6",text:k6,gold:[],offered:[f6]),Scene(id:"P1",text:p1,gold:[a1],offered:[a1]),Scene(id:"P2",text:p2,gold:[a2],offered:[a2]),Scene(id:"P3",text:p3,gold:[a3],offered:[a3]),Scene(id:"P4",text:p4,gold:[a4],offered:[]),Scene(id:"P5",text:p5,gold:[],offered:[a5]),Scene(id:"P6",text:p6,gold:[],offered:[a6])]
    for scene in scenes {
        let json=String(decoding:try JSONEncoder().encode(scene.offered),as:UTF8.self)
        let result=StoryMemoryProtocol.split(scene.text+StoryMemoryProtocol.marker+json)
        let verdict:String
        switch result.changes {
        case nil: verdict="pending"
        case let facts? where facts == scene.gold: verdict="correct"
        case let facts? where facts.isEmpty && !scene.gold.isEmpty: verdict="silent-miss"
        default: verdict="wrong"
        }
        print("NARRATIVE_CASE \(scene.id) \(verdict)")
        #expect(result.narration == scene.text)
        #expect(verdict != "wrong") // A forbidden fact always vetoes advancement.
    }
}

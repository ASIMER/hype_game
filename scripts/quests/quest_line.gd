extends Resource
class_name QuestLine
## A QUESTLINE — a named, ordered, narrated chain of QuestData steps with a single giver
## (Iteration 2). Saved as a .tres in `resources/questlines/`, scanned by the `Quests`
## autoload. The chain GATING itself is the steps' own `prereq` (step N prereqs step N-1);
## this resource only adds ORDERING + NARRATIVE + GIVER grouping for the UI.

enum Accent { AMBER, TEAL, GREEN }

@export var id: String = ""
@export var title: String = ""
## Questline blurb / lore shown in the detail modal when a step has no lore of its own.
@export_multiline var intro: String = ""
## Flavor NPC / faction contact that issues this line (per-giver reputation is Iteration 3).
@export var giver: String = ""
## Ordered step quest ids. quest_ids[0] is step 1, etc. (the source of truth for order).
@export var quest_ids: PackedStringArray = PackedStringArray()
## UI tint for the questline header strip + detail accent.
@export var accent: int = Accent.AMBER

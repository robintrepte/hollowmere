class_name CollectionPanel
extends JournalPanel
## Collections: every fish with its record size and the Wildling dex.

const COLLECTION_TABS := [["fish", "Fish"], ["dex", "Wildlings"]]

func _init(p: PlayerData = null, start_tab: String = "fish") -> void:
	super(p, start_tab)

func _tab_list() -> Array:
	return COLLECTION_TABS

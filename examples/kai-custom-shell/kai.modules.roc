import kai.Kai
import CustomShell

KaiModules := [].{
	changes : _ -> List(Kai.CommandChange)
	changes = |project| [
		Kai.CommandChange.Replace(
			CustomShell.implementation(project),
		),
	]
}

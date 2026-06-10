return {
	CanOverlapWithOtherParts = false,
	
	CanPlaceColor = Color3.fromRGB(255, 255, 255),
	CannotPlaceColor = Color3.fromRGB(255, 165, 0),
	
	LerpSpeed = 25,
	
	GridUnit = 1,
	RotationUnit = 15,
	
	GridIcons = {
		[1] = "rbxassetid://13406201389", -- Icon showing '1'
		[2] = "rbxassetid://13406201633", -- Icon showing '2'
		[4] = "rbxassetid://13406201887", -- Icon showing '4'
	},
	
	GridCycleKey = Enum.KeyCode.J,
	RotateY = Enum.KeyCode.R,
	Cancel = Enum.KeyCode.X
}

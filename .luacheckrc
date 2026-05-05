std = "lua51"

globals = {
  "FuRegisterClass", "Class",
  "CT_Tool", "CT_SourceTool", "CT_ViewTool",
  "Operator", "BiSrcOp", "TexSrcOp", "ThreeSrcOp", "ResolutionTool",
  "InImage", "InIntensity", "InSpeed", "InPhase",
  "InTearChance", "InScanlineStrength", "InSize", "InMonochrome",
  "InDirection", "InWarmth", "InAmount", "InDurationFrames", "InAt",
  "InMask", "Output", "OutImage",
  "Image",
  "LINKID_DataType", "LINK_Main", "INPID_InputControl",
  "INP_Default", "INP_MinScale", "INP_MaxScale",
  "REGS_Name", "REGS_Category", "REGS_OpIconString", "REGS_OpDescription",
  "REG_NoMotionBlurCtrls", "REG_NoBlendCtrls", "REG_OpNoMask",
}

files["fuses/**/*.fuse"] = {
  ignore = {"212", "213"},
}

allow_defined_top = true

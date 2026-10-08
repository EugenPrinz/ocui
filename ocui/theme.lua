-- ocui.theme
-- Default 24-bit color palette for T2/T3 screens. Override individual
-- fields on the returned table (or pass your own table with the same keys
-- to widgets) to reskin.

return {
  background  = 0x0F0F14,
  panel       = 0x16161D,
  border      = 0x33333D,
  borderFocus = 0x4C8BF5,
  text        = 0xE4E4E8,
  textDim     = 0x8A8A96,
  disabled    = 0x6A6A75,
  accent      = 0x4C8BF5,
  good        = 0x4CD787,
  warn        = 0xE0B341,
  bad         = 0xE0574C,
  barBg       = 0x232330,
  barFg       = 0x4C8BF5,

  button      = 0x33333D,
  buttonFocus = 0x4C8BF5,
  input       = 0x232330,
  inputFocus  = 0x2C2C3A,
  cursor      = 0xE4E4E8,
  selection   = 0x2B4C80,  -- selected row, list focused
  selectionDim = 0x33333D, -- selected row, list not focused
  header      = 0x232330,
  menu        = 0x232330,
  menuActive  = 0x4C8BF5,
  shadow      = 0x050508,
  status      = 0x232330,
  statusKey   = 0x4C8BF5,
}

{
    This file is part of the Free Pascal run time library.
    Copyright (c) 1999-2000 by Florian Klaempfl
    member of the Free Pascal development team

    Keyboard unit for Win32

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}
unit Keyboard;
interface
{$ifdef DEBUG}
uses
  windows;

var
  last_ir : Input_Record;
{$endif DEBUG}

{$i keybrdh.inc}

function KeyPressed:Boolean;

implementation

{ WARNING: Keyboard-Drivers (i.e. german) will only work under WinNT.
           95 and 98 do not support keyboard-drivers other than us for win32
           console-apps. So we always get the keys in us-keyboard layout
           from Win9x.
}

uses
{$ifndef DEBUG}
   Windows,
{$endif DEBUG}
   Dos,
   WinEvent;

{$i keyboard.inc}

const MaxQueueSize = 120;
      FrenchKeyboard = $040C040C;

type
  TFPKeyEventRecord = record
    ev: TKeyEventRecord;
    ShiftState: TEnhancedShiftState;
  end;
var
   keyboardeventqueue : array[0..maxqueuesize] of TFPKeyEventRecord;
   nextkeyevent,nextfreekeyevent : longint;
   newKeyEvent    : THandle;            {sinaled if key is available}
   lockVar        : TCriticalSection;   {for queue access}
   lastShiftState : byte;               {set by handler for PollShiftStateEvent}
   altNumActive   : boolean;            {for alt+0..9}
   altNumBuffer   : string [3];
   { used for keyboard specific stuff }
   KeyBoardLayout : HKL;
   Inited : Boolean;
   HasAltGr  : Boolean = false;


function KeyPressed:Boolean;
begin
  KeyPressed:=PollKeyEvent<>0;
end;

procedure incqueueindex(var l : longint);

  begin
     inc(l);
     { wrap around? }
     if l>maxqueuesize then
       l:=0;
  end;

function keyEventsInQueue : boolean;
begin
  keyEventsInQueue := (nextkeyevent <> nextfreekeyevent);
end;

function rightistruealt(dw:cardinal):boolean; // inline ?
// used to wrap checks for right alt/altgr.
begin
  rightistruealt:=true;
  if hasaltgr then
    rightistruealt:=(dw and RIGHT_ALT_PRESSED)=0;
end;


{ gets or peeks the next key from the queue, does not wait for new keys }
function getKeyEventFromQueue (VAR t : TFPKeyEventRecord; Peek : boolean) : boolean;
begin
  if not Inited then
    begin
    getKeyEventFromQueue := false;
    exit;
    end;
  EnterCriticalSection (lockVar);
  if keyEventsInQueue then
  begin
    t := keyboardeventqueue[nextkeyevent];
    if not peek then incqueueindex (nextkeyevent);
    getKeyEventFromQueue := true;
    if not keyEventsInQueue then ResetEvent (newKeyEvent);
  end else
  begin
    getKeyEventFromQueue := false;
    ResetEvent (newKeyEvent);
  end;
  LeaveCriticalSection (lockVar);
end;


{ gets the next key from the queue, does wait for new keys }
function getKeyEventFromQueueWait (VAR t : TFPKeyEventRecord) : boolean;
begin
  if not Inited then
    begin
      getKeyEventFromQueueWait := false;
      exit;
    end;
  WaitForSingleObject (newKeyEvent, dword(INFINITE));
  { force that we read a keyevent }
  while not(getKeyEventFromQueue (t, false)) do
    Sleep(0);
  getKeyEventFromQueueWait:=true;
end;

{ translate win32 shift-state to keyboard shift state }
function transShiftState (ControlKeyState : dword) : byte;
var b : byte;
begin
  b := 0;
  if ControlKeyState and SHIFT_PRESSED <> 0 then  { win32 makes no difference between left and right shift }
    b := b or kbShift;
  if (ControlKeyState and LEFT_CTRL_PRESSED <> 0) or
     (ControlKeyState  and RIGHT_CTRL_PRESSED <> 0) then
    b := b or kbCtrl;
  if (ControlKeyState and LEFT_ALT_PRESSED <> 0) or
     (ControlKeyState and RIGHT_ALT_PRESSED <> 0) then
    b := b or kbAlt;
  transShiftState := b;
end;

procedure UpdateKeyboardLayoutInfo(Force: Boolean);
var
  NewKeyboardLayout: HKL;

  procedure CheckAltGr;
  var i: integer;
  begin
    HasAltGr:=false;

    i:=$20;
    while i<$100 do
      begin
        // <MSDN>
        // For keyboard layouts that use the right-hand ALT key as a shift key
        // (for example, the French keyboard layout), the shift state is
        // represented by the value 6, because the right-hand ALT key is
        // converted internally into CTRL+ALT.
        // </MSDN>
        if (HIBYTE(VkKeyScanEx(chr(i),KeyBoardLayout))=6) then
          begin
            HasAltGr:=true;
            break;
          end;
      inc(i);
    end;
  end;

begin
  NewKeyBoardLayout:=GetKeyboardLayout(0);
  if force or (NewKeyboardLayout <> KeyBoardLayout) then
    begin
      KeyBoardLayout:=NewKeyboardLayout;
      CheckAltGr;
    end;
end;

{ The event-Handler thread from the unit event will call us if a key-event
  is available }

procedure HandleKeyboard(var ir:INPUT_RECORD);

  { translate win32 shift-state to keyboard shift state }
  function transEnhShiftState (ControlKeyState : dword) : TEnhancedShiftState;
  var b : TEnhancedShiftState;
  begin
    b := [];
    { Ctrl + Right Alt = AltGr }
    if HasAltGr and (ControlKeyState and RIGHT_ALT_PRESSED <> 0) and
                    ((ControlKeyState and LEFT_CTRL_PRESSED <> 0) or
                     (ControlKeyState and RIGHT_CTRL_PRESSED <> 0)) then
      begin
        Include(b, essAltGr);
        { if it's the right ctrl key, then we know it's RightCtrl+AltGr }
        if ControlKeyState and RIGHT_CTRL_PRESSED <> 0 then
          b:=b+[essCtrl,essRightCtrl];
        { if it's the left ctrl key, unfortunately, we can't distinguish between
          LeftCtrl+AltGr and AltGr alone, so we assume AltGr only }
      end
    else
      begin
        if ControlKeyState and LEFT_CTRL_PRESSED <> 0 then
          b:=b+[essCtrl,essLeftCtrl];
        if ControlKeyState and RIGHT_ALT_PRESSED <> 0 then
          b:=b+[essAlt,essRightAlt];
        if ControlKeyState and RIGHT_CTRL_PRESSED <> 0 then
          b:=b+[essCtrl,essRightCtrl];
      end;
    if ControlKeyState and LEFT_ALT_PRESSED <> 0 then
      b:=b+[essAlt,essLeftAlt];
    if ControlKeyState and SHIFT_PRESSED <> 0 then  { win32 makes no difference between left and right shift }
      Include(b,essShift);
    if ControlKeyState and NUMLOCK_ON <> 0 then
      Include(b,essNumLockOn);
    if ControlKeyState and CAPSLOCK_ON <> 0 then
      Include(b,essCapsLockOn);
    if ControlKeyState and SCROLLLOCK_ON <> 0 then
      Include(b,essScrollLockOn);
    if (GetKeyState(VK_LSHIFT) and $8000) <> 0 then
      b:=b+[essShift,essLeftShift];
    if (GetKeyState(VK_RSHIFT) and $8000) <> 0 then
      b:=b+[essShift,essRightShift];
    if (GetKeyState(VK_NUMLOCK) and $8000) <> 0 then
      Include(b,essNumLockPressed);
    if (GetKeyState(VK_CAPITAL) and $8000) <> 0 then
      Include(b,essCapsLockPressed);
    if (GetKeyState(VK_SCROLL) and $8000) <> 0 then
      Include(b,essScrollLockPressed);
    transEnhShiftState := b;
  end;

var
   i      : longint;
   c      : word;
   altc : char;
   addThis: boolean;
begin
  { Since Windows supports switching between different input locales, the
    current input locale might change, while the app is still running. In
    fact, this is the default configuration for languages, that use a Non
    Latin script (e.g. Cyrillic, Greek, etc.) - they use this feature to
    switch between Latin and the Non Latin layout. But Windows in general
    can be configured to switch between any number of different keyboard
    layouts, so it's not a feature, limited only to Non Latin scripts.

    GUI apps get an WM_INPUTLANGCHANGE message in the case the keyboard layout
    changes, but unfortunately, console apps get no such notification. Therefore
    we must check and update our idea of the current keyboard layout on every
    key event we receive. :(

    Note: This doesn't actually work, due to this Windows bug:
      https://github.com/Microsoft/console/issues/83
    Since Microsoft considers this an open bug, and since there's no known
    workaround, we still poll the keyboard layout, in hope that some day
    Microsoft might fix this and issue a Windows Update. }
  UpdateKeyboardLayoutInfo(False);

  with ir.Event.KeyEvent do
    begin
       { key up events are ignored (except alt) }
       if bKeyDown then
         begin
            EnterCriticalSection (lockVar);
            for i:=1 to wRepeatCount do
              begin
                 addThis := true;
                 if (dwControlKeyState and LEFT_ALT_PRESSED <> 0) or
                    (dwControlKeyState and RIGHT_ALT_PRESSED <> 0) then            {alt pressed}
                   if ((wVirtualKeyCode >= $60) and (wVirtualKeyCode <= $69)) or
                      ((dwControlKeyState and ENHANCED_KEY = 0) and
                       (wVirtualKeyCode in [$C{VK_CLEAR generated by keypad 5},
                                            $21 {VK_PRIOR (PgUp) 9},
                                            $22 {VK_NEXT (PgDown) 3},
                                            $23 {VK_END 1},
                                            $24 {VK_HOME 7},
                                            $25 {VK_LEFT 4},
                                            $26 {VK_UP 8},
                                            $27 {VK_RIGHT 6},
                                            $28 {VK_DOWN 2},
                                            $2D {VK_INSERT 0}])) then   {0..9 on NumBlock}
                   begin
                     if length (altNumBuffer) = 3 then
                       delete (altNumBuffer,1,1);
                     case wVirtualKeyCode of
                       $60..$69 : altc:=char (wVirtualKeyCode-48);
                       $c  : altc:='5';
                       $21 : altc:='9';
                       $22 : altc:='3';
                       $23 : altc:='1';
                       $24 : altc:='7';
                       $25 : altc:='4';
                       $26 : altc:='8';
                       $27 : altc:='6';
                       $28 : altc:='2';
                       $2D : altc:='0';
                     end;
                     altNumBuffer := altNumBuffer + altc;
                     altNumActive   := true;
                     addThis := false;
                   end else
                   begin
                     altNumActive   := false;
                     altNumBuffer   := '';
                   end;
                 if addThis then
                 begin
                   keyboardeventqueue[nextfreekeyevent].ev:=
                     ir.Event.KeyEvent;
                   keyboardeventqueue[nextfreekeyevent].ShiftState:=
                     transEnhShiftState(dwControlKeyState);
                   incqueueindex(nextfreekeyevent);
                 end;
              end;

            lastShiftState := transShiftState (dwControlKeyState);  {save it for PollShiftStateEvent}
            SetEvent (newKeyEvent);             {event that a new key is available}
            LeaveCriticalSection (lockVar);
         end
       else
         begin
           lastShiftState := transShiftState (dwControlKeyState);   {save it for PollShiftStateEvent}
           {for alt-number we have to look for alt-key release}
           if altNumActive then
            begin
              if (wVirtualKeyCode = $12) then    {alt-released}
               begin
                 if altNumBuffer <> '' then       {numbers with alt pressed?}
                  begin
                    Val (altNumBuffer, c, i);
                    if (i = 0) and (c <= 255) then {valid number?}
                     begin                          {add to queue}
                       fillchar (ir, sizeof (ir), 0);
                       bKeyDown := true;
                       UnicodeChar := WideChar (c);
                                                {and add to queue}
                       EnterCriticalSection (lockVar);
                       keyboardeventqueue[nextfreekeyevent].ev:=ir.Event.KeyEvent;
                       keyboardeventqueue[nextfreekeyevent].ShiftState:=transEnhShiftState(dwControlKeyState);
                       incqueueindex(nextfreekeyevent);
                       SetEvent (newKeyEvent);      {event that a new key is available}
                       LeaveCriticalSection (lockVar);
                     end;
                  end;
                 altNumActive   := false;         {clear alt-buffer}
                 altNumBuffer   := '';
               end;
            end;
         end;
    end;
end;




procedure SysInitKeyboard;
begin
   UpdateKeyboardLayoutInfo(True);
   lastShiftState := 0;
   FlushConsoleInputBuffer(StdInputHandle);
   newKeyEvent := CreateEvent (nil,        // address of security attributes
                               true,       // flag for manual-reset event
                               false,      // flag for initial state
                               nil);       // address of event-object name
   if newKeyEvent = INVALID_HANDLE_VALUE then
    begin
      // what to do here ????
      RunError (217);
    end;
   InitializeCriticalSection (lockVar);
   altNumActive := false;
   altNumBuffer := '';

   nextkeyevent:=0;
   nextfreekeyevent:=0;
   SetKeyboardEventHandler (@HandleKeyboard);
   Inited:=true;
end;

procedure SysDoneKeyboard;
begin
  SetKeyboardEventHandler(nil);     {hangs???}
  DeleteCriticalSection (lockVar);
  FlushConsoleInputBuffer(StdInputHandle);
  closeHandle (newKeyEvent);
  Inited:=false;
end;

{$define USEKEYCODES}

{Translatetable Win32 -> Dos for Special Keys = Function Key, Cursor Keys
 and Keys other than numbers on numblock (to make fv happy) }
{combinations under dos: Shift+Ctrl: same as Ctrl
                         Shift+Alt : same as alt
                         Ctrl+Alt  : nothing (here we get it like alt)}
{$ifdef USEKEYCODES}
   { use positive values for ScanCode we want to set
   0 for key where we should leave the scancode
   -1 for OEM specifc keys
   -2 for unassigned
   -3 for Kanji systems ???
   }
const
  Unassigned = -2;
  Kanji = -3;
  OEM_specific = -1;
  KeyToQwertyScan : array [0..255] of integer =
  (
  { 00 } 0,
  { 01 VK_LBUTTON } 0,
  { 02 VK_RBUTTON } 0,
  { 03 VK_CANCEL } 0,
  { 04 VK_MBUTTON } 0,
  { 05 unassigned } -2,
  { 06 unassigned } -2,
  { 07 unassigned } -2,
  { 08 VK_BACK } $E,
  { 09 VK_TAB } $F,
  { 0A unassigned } -2,
  { 0B unassigned } -2,
  { 0C VK_CLEAR ?? } 0,
  { 0D VK_RETURN } 0,
  { 0E unassigned } -2,
  { 0F unassigned } -2,
  { 10 VK_SHIFT } 0,
  { 11 VK_CONTROL } 0,
  { 12 VK_MENU (Alt key) } 0,
  { 13 VK_PAUSE } 0,
  { 14 VK_CAPITAL (Caps Lock) } 0,
  { 15 Reserved for Kanji systems} -3,
  { 16 Reserved for Kanji systems} -3,
  { 17 Reserved for Kanji systems} -3,
  { 18 Reserved for Kanji systems} -3,
  { 19 Reserved for Kanji systems} -3,
  { 1A unassigned } -2,
  { 1B VK_ESCAPE } $1,
  { 1C Reserved for Kanji systems} -3,
  { 1D Reserved for Kanji systems} -3,
  { 1E Reserved for Kanji systems} -3,
  { 1F Reserved for Kanji systems} -3,
  { 20 VK_SPACE} 0,
  { 21 VK_PRIOR (PgUp) } 0,
  { 22 VK_NEXT (PgDown) } 0,
  { 23 VK_END } 0,
  { 24 VK_HOME } 0,
  { 25 VK_LEFT } 0,
  { 26 VK_UP } 0,
  { 27 VK_RIGHT } 0,
  { 28 VK_DOWN } 0,
  { 29 VK_SELECT ??? } 0,
  { 2A OEM specific !! } -1,
  { 2B VK_EXECUTE } 0,
  { 2C VK_SNAPSHOT } 0,
  { 2D VK_INSERT } 0,
  { 2E VK_DELETE } 0,
  { 2F VK_HELP } 0,
  { 30 VK_0 '0' } 11,
  { 31 VK_1 '1' } 2,
  { 32 VK_2 '2' } 3,
  { 33 VK_3 '3' } 4,
  { 34 VK_4 '4' } 5,
  { 35 VK_5 '5' } 6,
  { 36 VK_6 '6' } 7,
  { 37 VK_7 '7' } 8,
  { 38 VK_8 '8' } 9,
  { 39 VK_9 '9' } 10,
  { 3A unassigned } -2,
  { 3B unassigned } -2,
  { 3C unassigned } -2,
  { 3D unassigned } -2,
  { 3E unassigned } -2,
  { 3F unassigned } -2,
  { 40 unassigned } -2,
  { 41 VK_A 'A' } $1E,
  { 42 VK_B 'B' } $30,
  { 43 VK_C 'C' } $2E,
  { 44 VK_D 'D' } $20,
  { 45 VK_E 'E' } $12,
  { 46 VK_F 'F' } $21,
  { 47 VK_G 'G' } $22,
  { 48 VK_H 'H' } $23,
  { 49 VK_I 'I' } $17,
  { 4A VK_J 'J' } $24,
  { 4B VK_K 'K' } $25,
  { 4C VK_L 'L' } $26,
  { 4D VK_M 'M' } $32,
  { 4E VK_N 'N' } $31,
  { 4F VK_O 'O' } $18,
  { 50 VK_P 'P' } $19,
  { 51 VK_Q 'Q' } $10,
  { 52 VK_R 'R' } $13,
  { 53 VK_S 'S' } $1F,
  { 54 VK_T 'T' } $14,
  { 55 VK_U 'U' } $16,
  { 56 VK_V 'V' } $2F,
  { 57 VK_W 'W' } $11,
  { 58 VK_X 'X' } $2D,
  { 59 VK_Y 'Y' } $15,
  { 5A VK_Z 'Z' } $2C,
  { 5B unassigned } -2,
  { 5C unassigned } -2,
  { 5D unassigned } -2,
  { 5E unassigned } -2,
  { 5F unassigned } -2,
  { 60 VK_NUMPAD0 NumKeyPad '0' } 11,
  { 61 VK_NUMPAD1 NumKeyPad '1' } 2,
  { 62 VK_NUMPAD2 NumKeyPad '2' } 3,
  { 63 VK_NUMPAD3 NumKeyPad '3' } 4,
  { 64 VK_NUMPAD4 NumKeyPad '4' } 5,
  { 65 VK_NUMPAD5 NumKeyPad '5' } 6,
  { 66 VK_NUMPAD6 NumKeyPad '6' } 7,
  { 67 VK_NUMPAD7 NumKeyPad '7' } 8,
  { 68 VK_NUMPAD8 NumKeyPad '8' } 9,
  { 69 VK_NUMPAD9 NumKeyPad '9' } 10,
  { 6A VK_MULTIPLY } 0,
  { 6B VK_ADD } 0,
  { 6C VK_SEPARATOR } 0,
  { 6D VK_SUBSTRACT } 0,
  { 6E VK_DECIMAL } 0,
  { 6F VK_DIVIDE } 0,
  { 70 VK_F1 'F1' } $3B,
  { 71 VK_F2 'F2' } $3C,
  { 72 VK_F3 'F3' } $3D,
  { 73 VK_F4 'F4' } $3E,
  { 74 VK_F5 'F5' } $3F,
  { 75 VK_F6 'F6' } $40,
  { 76 VK_F7 'F7' } $41,
  { 77 VK_F8 'F8' } $42,
  { 78 VK_F9 'F9' } $43,
  { 79 VK_F10 'F10' } $44,
  { 7A VK_F11 'F11' } $57,
  { 7B VK_F12 'F12' } $58,
  { 7C VK_F13 } 0,
  { 7D VK_F14 } 0,
  { 7E VK_F15 } 0,
  { 7F VK_F16 } 0,
  { 80 VK_F17 } 0,
  { 81 VK_F18 } 0,
  { 82 VK_F19 } 0,
  { 83 VK_F20 } 0,
  { 84 VK_F21 } 0,
  { 85 VK_F22 } 0,
  { 86 VK_F23 } 0,
  { 87 VK_F24 } 0,
  { 88 unassigned } -2,
  { 89 VK_NUMLOCK } 0,
  { 8A VK_SCROLL } 0,
  { 8B unassigned } -2,
  { 8C unassigned } -2,
  { 8D unassigned } -2,
  { 8E unassigned } -2,
  { 8F unassigned } -2,
  { 90 unassigned } -2,
  { 91 unassigned } -2,
  { 92 unassigned } -2,
  { 93 unassigned } -2,
  { 94 unassigned } -2,
  { 95 unassigned } -2,
  { 96 unassigned } -2,
  { 97 unassigned } -2,
  { 98 unassigned } -2,
  { 99 unassigned } -2,
  { 9A unassigned } -2,
  { 9B unassigned } -2,
  { 9C unassigned } -2,
  { 9D unassigned } -2,
  { 9E unassigned } -2,
  { 9F unassigned } -2,
  { A0 unassigned } -2,
  { A1 unassigned } -2,
  { A2 unassigned } -2,
  { A3 unassigned } -2,
  { A4 unassigned } -2,
  { A5 unassigned } -2,
  { A6 unassigned } -2,
  { A7 unassigned } -2,
  { A8 unassigned } -2,
  { A9 unassigned } -2,
  { AA unassigned } -2,
  { AB unassigned } -2,
  { AC unassigned } -2,
  { AD unassigned } -2,
  { AE unassigned } -2,
  { AF unassigned } -2,
  { B0 unassigned } -2,
  { B1 unassigned } -2,
  { B2 unassigned } -2,
  { B3 unassigned } -2,
  { B4 unassigned } -2,
  { B5 unassigned } -2,
  { B6 unassigned } -2,
  { B7 unassigned } -2,
  { B8 unassigned } -2,
  { B9 unassigned } -2,
  { BA OEM specific } 0,
  { BB OEM specific } 0,
  { BC OEM specific } 0,
  { BD OEM specific } 0,
  { BE OEM specific } 0,
  { BF OEM specific } 0,
  { C0 OEM specific } 0,
  { C1 unassigned } -2,
  { C2 unassigned } -2,
  { C3 unassigned } -2,
  { C4 unassigned } -2,
  { C5 unassigned } -2,
  { C6 unassigned } -2,
  { C7 unassigned } -2,
  { C8 unassigned } -2,
  { C9 unassigned } -2,
  { CA unassigned } -2,
  { CB unassigned } -2,
  { CC unassigned } -2,
  { CD unassigned } -2,
  { CE unassigned } -2,
  { CF unassigned } -2,
  { D0 unassigned } -2,
  { D1 unassigned } -2,
  { D2 unassigned } -2,
  { D3 unassigned } -2,
  { D4 unassigned } -2,
  { D5 unassigned } -2,
  { D6 unassigned } -2,
  { D7 unassigned } -2,
  { D8 unassigned } -2,
  { D9 unassigned } -2,
  { DA unassigned } -2,
  { DB OEM specific } 0,
  { DC OEM specific } 0,
  { DD OEM specific } 0,
  { DE OEM specific } 0,
  { DF OEM specific } 0,
  { E0 OEM specific } 0,
  { E1 OEM specific } 0,
  { E2 OEM specific } 0,
  { E3 OEM specific } 0,
  { E4 OEM specific } 0,
  { E5 unassigned } -2,
  { E6 OEM specific } 0,
  { E7 unassigned } -2,
  { E8 unassigned } -2,
  { E9 OEM specific } 0,
  { EA OEM specific } 0,
  { EB OEM specific } 0,
  { EC OEM specific } 0,
  { ED OEM specific } 0,
  { EE OEM specific } 0,
  { EF OEM specific } 0,
  { F0 OEM specific } 0,
  { F1 OEM specific } 0,
  { F2 OEM specific } 0,
  { F3 OEM specific } 0,
  { F4 OEM specific } 0,
  { F5 OEM specific } 0,
  { F6 unassigned } -2,
  { F7 unassigned } -2,
  { F8 unassigned } -2,
  { F9 unassigned } -2,
  { FA unassigned } -2,
  { FB unassigned } -2,
  { FC unassigned } -2,
  { FD unassigned } -2,
  { FE unassigned } -2,
  { FF unassigned } -2
  );
{$endif  USEKEYCODES}
type TTEntryT = packed record
                  n,s,c,a : byte;   {normal,shift, ctrl, alt, normal only for f11,f12}
                end;

CONST
 DosTT : ARRAY [$3B..$58] OF TTEntryT =
  ((n : $3B; s : $54; c : $5E; a: $68),      {3B F1}
   (n : $3C; s : $55; c : $5F; a: $69),      {3C F2}
   (n : $3D; s : $56; c : $60; a: $6A),      {3D F3}
   (n : $3E; s : $57; c : $61; a: $6B),      {3E F4}
   (n : $3F; s : $58; c : $62; a: $6C),      {3F F5}
   (n : $40; s : $59; c : $63; a: $6D),      {40 F6}
   (n : $41; s : $5A; c : $64; a: $6E),      {41 F7}
   (n : $42; s : $5B; c : $65; a: $6F),      {42 F8}
   (n : $43; s : $5C; c : $66; a: $70),      {43 F9}
   (n : $44; s : $5D; c : $67; a: $71),      {44 F10}
   (n : $45; s : $00; c : $00; a: $00),      {45 ???}
   (n : $46; s : $00; c : $00; a: $00),      {46 ???}
   (n : $47; s : $47; c : $77; a: $97),      {47 Home}
   (n : $48; s : $00; c : $8D; a: $98),      {48 Up}
   (n : $49; s : $49; c : $84; a: $99),      {49 PgUp}
   (n : $4A; s : $00; c : $8E; a: $4A),      {4A -}
   (n : $4B; s : $4B; c : $73; a: $9B),      {4B Left}
   (n : $4C; s : $00; c : $00; a: $00),      {4C ???}
   (n : $4D; s : $4D; c : $74; a: $9D),      {4D Right}
   (n : $4E; s : $00; c : $90; a: $4E),      {4E +}
   (n : $4F; s : $4F; c : $75; a: $9F),      {4F End}
   (n : $50; s : $50; c : $91; a: $A0),      {50 Down}
   (n : $51; s : $51; c : $76; a: $A1),      {51 PgDown}
   (n : $52; s : $52; c : $92; a: $A2),      {52 Insert}
   (n : $53; s : $53; c : $93; a: $A3),      {53 Del}
   (n : $54; s : $00; c : $00; a: $00),      {54 ???}
   (n : $55; s : $00; c : $00; a: $00),      {55 ???}
   (n : $56; s : $00; c : $00; a: $00),      {56 ???}
   (n : $85; s : $87; c : $89; a: $8B),      {57 F11}
   (n : $86; s : $88; c : $8A; a: $8C));     {58 F12}

 DosTT09 : ARRAY [$02..$0F] OF TTEntryT =
  ((n : $00; s : $00; c : $00; a: $78),      {02 1 }
   (n : $00; s : $00; c : $00; a: $79),      {03 2 }
   (n : $00; s : $00; c : $00; a: $7A),      {04 3 }
   (n : $00; s : $00; c : $00; a: $7B),      {05 4 }
   (n : $00; s : $00; c : $00; a: $7C),      {06 5 }
   (n : $00; s : $00; c : $00; a: $7D),      {07 6 }
   (n : $00; s : $00; c : $00; a: $7E),      {08 7 }
   (n : $00; s : $00; c : $00; a: $7F),      {09 8 }
   (n : $00; s : $00; c : $00; a: $80),      {0A 9 }
   (n : $00; s : $00; c : $00; a: $81),      {0B 0 }
   (n : $00; s : $00; c : $00; a: $82),      {0C � }
   (n : $00; s : $00; c : $00; a: $00),      {0D}
   (n : $00; s : $00; c : $00; a: $00),      {0E Backspace}
   (n : $00; s : $0F; c : $94; a: $00));     {0F Tab }


function WideCharToOemCpChar(WC: WideChar): Char;
var
  Res: Char;
begin
  if WideCharToMultiByte(CP_OEMCP,0,@WC,1,@Res,1,nil,nil)=0 then
    Res:=#0;
  WideCharToOemCpChar:=Res;
end;


function SysTranslateKeyEvent(KeyEvent: TKeyEvent): TKeyEvent;
begin
  if KeyEvent and $03000000 = $03000000 then
   begin
     if KeyEvent and $000000FF <> 0 then
     begin
       SysTranslateKeyEvent := KeyEvent and $00FFFFFF;
       exit;
     end;
     {translate function-keys and other specials, ascii-codes are already ok}
     case (KeyEvent AND $0000FF00) shr 8 of
       {F1..F10}
       $3B..$44     : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdF1 + ((KeyEvent AND $0000FF00) SHR 8) - $3B + $02000000;
       {F11,F12}
       $85..$86     : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdF11 + ((KeyEvent AND $0000FF00) SHR 8) - $85 + $02000000;
       {Shift F1..F10}
       $54..$5D     : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdF1 + ((KeyEvent AND $0000FF00) SHR 8) - $54 + $02000000;
       {Shift F11,F12}
       $87..$88     : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdF11 + ((KeyEvent AND $0000FF00) SHR 8) - $87 + $02000000;
       {Alt F1..F10}
       $68..$71     : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdF1 + ((KeyEvent AND $0000FF00) SHR 8) - $68 + $02000000;
       {Alt F11,F12}
       $8B..$8C     : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdF11 + ((KeyEvent AND $0000FF00) SHR 8) - $8B + $02000000;
       {Ctrl F1..F10}
       $5E..$67     : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdF1 + ((KeyEvent AND $0000FF00) SHR 8) - $5E + $02000000;
       {Ctrl F11,F12}
       $89..$8A     : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdF11 + ((KeyEvent AND $0000FF00) SHR 8) - $89 + $02000000;

       {normal,ctrl,alt}
       $47,$77,$97  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdHome + $02000000;
       $48,$8D,$98  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdUp + $02000000;
       $49,$84,$99  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdPgUp + $02000000;
       $4b,$73,$9B  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdLeft + $02000000;
       $4d,$74,$9D  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdRight + $02000000;
       $4f,$75,$9F  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdEnd + $02000000;
       $50,$91,$A0  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdDown + $02000000;
       $51,$76,$A1  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdPgDn + $02000000;
       $52,$92,$A2  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdInsert + $02000000;
       $53,$93,$A3  : SysTranslateKeyEvent := (KeyEvent AND $FCFF0000) + kbdDelete + $02000000;
     else
       SysTranslateKeyEvent := KeyEvent;
     end;
   end else
     SysTranslateKeyEvent := KeyEvent;
end;


function SysGetShiftState: Byte;

begin
  {may be better to save the last state and return that if no key is in buffer???}
  SysGetShiftState:= lastShiftState;
end;


function TranslateEnhancedKeyEvent (t : TFPKeyEventRecord) : TEnhancedKeyEvent;
var key : TEnhancedKeyEvent;
{$ifdef  USEKEYCODES}
    ScanCode  : byte;
{$endif  USEKEYCODES}
    b   : byte;
begin
  Key := NilEnhancedKeyEvent;
  if t.ev.bKeyDown then
  begin
    { unicode-char is <> 0 if not a specal key }
    { we return it here otherwise we have to translate more later }
    if t.ev.UnicodeChar <> WideChar(0) then
    begin
      if (t.ev.dwControlKeyState and ENHANCED_KEY <> 0) and
         (t.ev.wVirtualKeyCode = $DF) then
        begin
          t.ev.dwControlKeyState:=t.ev.dwControlKeyState and not ENHANCED_KEY;
          t.ev.wVirtualKeyCode:=VK_DIVIDE;
          t.ev.UnicodeChar:='/';
        end;
      {drivers needs scancode, we return it here as under dos and linux
       with $03000000 = the lowest two bytes is the physical representation}
{$ifdef  USEKEYCODES}
      Scancode:=KeyToQwertyScan[t.ev.wVirtualKeyCode AND $00FF];
      If ScanCode>0 then
        t.ev.wVirtualScanCode:=ScanCode;
      Key.UnicodeChar := t.ev.UnicodeChar;
      Key.AsciiChar := WideCharToOemCpChar(t.ev.UnicodeChar);
      Key.VirtualScanCode := byte (Key.AsciiChar) + (t.ev.wVirtualScanCode shl 8);
      Key.ShiftState := t.ShiftState;
      if essAlt in t.ShiftState then
        Key.VirtualScanCode := Key.VirtualScanCode and $FF00;
{$else not USEKEYCODES}
      Key.UnicodeChar := t.ev.UnicodeChar;
      Key.AsciiChar := WideCharToOemCpChar(t.ev.UnicodeChar);
      Key.VirtualScanCode := byte (Key.AsciiChar) + ((t.ev.wVirtualScanCode AND $00FF) shl 8);
{$endif not USEKEYCODES}
    end else
    begin
{$ifdef  USEKEYCODES}
      Scancode:=KeyToQwertyScan[t.ev.wVirtualKeyCode AND $00FF];
      If ScanCode>0 then
        t.ev.wVirtualScanCode:=ScanCode;
{$endif not USEKEYCODES}
      TranslateEnhancedKeyEvent := NilEnhancedKeyEvent;
      { ignore shift,ctrl,alt,numlock,capslock alone }
      case t.ev.wVirtualKeyCode of
        $0010,         {shift}
        $0011,         {ctrl}
        $0012,         {alt}
        $0014,         {capslock}
        $0090,         {numlock}
        $0091,         {scrollock}
        { This should be handled !! }
        { these last two are OEM specific
          this is not good !!! }
        $00DC,         {^ : next key i.e. a is modified }
        { Strange on my keyboard this corresponds to double point over i or u PM }
        $00DD: exit;   {� and ` : next key i.e. e is modified }
      end;

      Key.VirtualScanCode := t.ev.wVirtualScanCode shl 8;  { make lower 8 bit=0 like under dos }
    end;
    { Handling of ~ key as AltGr 2 }
    { This is also French keyboard specific !! }
    { but without this I can not get a ~ !! PM }
    { MvdV: not rightruealtised, since it already has frenchkbd guard}
    if (t.ev.wVirtualKeyCode=$32) and
       (KeyBoardLayout = FrenchKeyboard) and
       (t.ev.dwControlKeyState and RIGHT_ALT_PRESSED <> 0) then
    begin
      Key.UnicodeChar := '~';
      Key.AsciiChar := '~';
      Key.VirtualScanCode := (Key.VirtualScanCode and $ff00) or ord('~');
    end;
    { ok, now add Shift-State }
    Key.ShiftState := t.ShiftState;

    { Reset Ascii-Char if Alt+Key, fv needs that, may be we
      need it for other special keys too
      18 Sept 1999 AD: not for right Alt i.e. for AltGr+� = \ on german keyboard }
    if (essAlt in t.ShiftState) or
    (*
      { yes, we need it for cursor keys, 25=left, 26=up, 27=right,28=down}
      {aggg, this will not work because esc is also virtualKeyCode 27!!}
      {if (t.ev.wVirtualKeyCode >= 25) and (t.ev.wVirtualKeyCode <= 28) then}
        no VK_ESCAPE is $1B !!
        there was a mistake :
         VK_LEFT is $25 not 25 !! *)
       { not $2E VK_DELETE because its only the Keypad point !! PM }
      (t.ev.wVirtualKeyCode in [$21..$28,$2C,$2D,$2F]) then
      { if t.ev.wVirtualScanCode in [$47..$49,$4b,$4d,$4f,$50..$53] then}
        Key.VirtualScanCode := Key.VirtualScanCode and $FF00;

    {and translate to dos-scancodes to make fv happy, we will convert this
     back in translateKeyEvent}

    if (t.ev.wVirtualScanCode >= low (DosTT)) and
       (t.ev.wVirtualScanCode <= high (dosTT)) then
    begin
      b := 0;
      if essAlt in t.ShiftState then
        b := DosTT[t.ev.wVirtualScanCode].a
      else
      if essCtrl in t.ShiftState then
        b := DosTT[t.ev.wVirtualScanCode].c
      else
      if essShift in t.ShiftState then
        b := DosTT[t.ev.wVirtualScanCode].s
      else
        b := DosTT[t.ev.wVirtualScanCode].n;
      if b <> 0 then
        Key.VirtualScanCode := (Key.VirtualScanCode and $00FF) or (cardinal (b) shl 8);
    end;

    {Alt-0 to Alt-9}
    if (t.ev.wVirtualScanCode >= low (DosTT09)) and
       (t.ev.wVirtualScanCode <= high (dosTT09)) then
    begin
      b := 0;
      if essAlt in t.ShiftState then
        b := DosTT09[t.ev.wVirtualScanCode].a
      else
      if essCtrl in t.ShiftState then
        b := DosTT09[t.ev.wVirtualScanCode].c
      else
      if essShift in t.ShiftState then
        b := DosTT09[t.ev.wVirtualScanCode].s
      else
        b := DosTT09[t.ev.wVirtualScanCode].n;
      if b <> 0 then
        Key.VirtualScanCode := cardinal (b) shl 8;
    end;
  end;
  TranslateEnhancedKeyEvent := Key;
end;

function SysGetEnhancedKeyEvent: TEnhancedKeyEvent;
var t   : TFPKeyEventRecord;
    key : TEnhancedKeyEvent;
begin
  key := NilEnhancedKeyEvent;
  repeat
     if getKeyEventFromQueueWait (t) then
       key := TranslateEnhancedKeyEvent (t);
  until key <> NilEnhancedKeyEvent;
  SysGetEnhancedKeyEvent := key;
end;

function SysPollEnhancedKeyEvent: TEnhancedKeyEvent;
var t   : TFPKeyEventRecord;
    k   : TEnhancedKeyEvent;
begin
  SysPollEnhancedKeyEvent := NilEnhancedKeyEvent;
  if getKeyEventFromQueue (t, true) then
  begin
    { we get an enty for shift, ctrl, alt... }
    k := TranslateEnhancedKeyEvent (t);
    while (k = NilEnhancedKeyEvent) do
    begin
      getKeyEventFromQueue (t, false);  {remove it}
      if not getKeyEventFromQueue (t, true) then exit;
      k := TranslateEnhancedKeyEvent (t)
    end;
    SysPollEnhancedKeyEvent := k;
  end;
end;

Const
  SysKeyboardDriver : TKeyboardDriver = (
    InitDriver : @SysInitKeyBoard;
    DoneDriver : @SysDoneKeyBoard;
    GetKeyevent : Nil;
    PollKeyEvent : Nil;
    GetShiftState : @SysGetShiftState;
    TranslateKeyEvent : @SysTranslateKeyEvent;
    TranslateKeyEventUnicode : Nil;
    GetEnhancedKeyEvent : @SysGetEnhancedKeyEvent;
    PollEnhancedKeyEvent : @SysPollEnhancedKeyEvent;
  );


begin
  SetKeyBoardDriver(SysKeyBoardDriver);
end.

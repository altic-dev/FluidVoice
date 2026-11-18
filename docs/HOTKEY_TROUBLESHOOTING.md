# Hotkey Troubleshooting

## FluidVoice does not detect a mouse side button

Mouse utilities can intercept or replace a button press before FluidVoice receives it. Common examples include Logitech G HUB, Logi Options+, SteerMouse, BetterMouse, and vendor-specific profile software.

1. Open the mouse utility and select the active mouse and application profile.
2. Check the button diagram or assignment list for the side button you want to use.
3. Remove any app launch, keyboard shortcut, macro, or gesture assigned to that button.
4. Reset the button to its default/native action, such as **Forward**, **Back**, or **Use Default**.
5. Return to FluidVoice, start shortcut capture again, and press the button.

Also check whether the mouse utility changes profiles automatically when FluidVoice is active. If the button still does not register, temporarily quit the utility and try shortcut capture again. If it works while the utility is closed, the interception is happening in that utility or one of its profiles.

## FluidVoice does not accept F13–F19

FluidVoice's hotkey field records an actual keyboard event. Typing or pasting the text `F18`, or clicking a virtual key that does not emit an F18 key event, will not assign that shortcut.

F13–F19 work only when your keyboard, Stream Deck setup, or remapping tool can emit those function-key events. If your physical keyboard has no F18 key, use one of these options:

- Choose a low-conflict shortcut your keyboard can produce directly.
- Map an unused key to `F18`, then press the mapped key while FluidVoice is recording the shortcut. [Karabiner-Elements remapping guide](https://karabiner-elements.pqrs.org/docs/manual/configuration/configure-simple-modifications/)
- Set up a Stream Deck Hotkey action. Enter `F18` in that action by pressing an `F18` key or a key you mapped to `F18`. Then press the Stream Deck button while FluidVoice is recording the shortcut. [Stream Deck Hotkey guide](https://help.elgato.com/hc/en-us/articles/360028234471-Elgato-Stream-Deck-System-Actions-Hotkey-Open-Website-Multimedia)

After FluidVoice records F18, any device configured to emit the same F18 event can trigger dictation.

#include <SDL3/SDL.h>

#include <stdio.h>

static const char *button_name(Uint8 button)
{
    switch ((SDL_GamepadButton)button) {
    case SDL_GAMEPAD_BUTTON_SOUTH: return "south";
    case SDL_GAMEPAD_BUTTON_EAST: return "east";
    case SDL_GAMEPAD_BUTTON_WEST: return "west";
    case SDL_GAMEPAD_BUTTON_NORTH: return "north";
    case SDL_GAMEPAD_BUTTON_BACK: return "back";
    case SDL_GAMEPAD_BUTTON_GUIDE: return "guide";
    case SDL_GAMEPAD_BUTTON_START: return "start";
    case SDL_GAMEPAD_BUTTON_LEFT_STICK: return "left_stick";
    case SDL_GAMEPAD_BUTTON_RIGHT_STICK: return "right_stick";
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return "left_shoulder";
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return "right_shoulder";
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return "dpad_up";
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return "dpad_down";
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return "dpad_left";
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return "dpad_right";
    case SDL_GAMEPAD_BUTTON_MISC1: return "misc1";
    case SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1: return "right_paddle1";
    case SDL_GAMEPAD_BUTTON_LEFT_PADDLE1: return "left_paddle1";
    case SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2: return "right_paddle2";
    case SDL_GAMEPAD_BUTTON_LEFT_PADDLE2: return "left_paddle2";
    case SDL_GAMEPAD_BUTTON_TOUCHPAD: return "touchpad";
    case SDL_GAMEPAD_BUTTON_MISC2: return "misc2";
    case SDL_GAMEPAD_BUTTON_MISC3: return "misc3";
    case SDL_GAMEPAD_BUTTON_MISC4: return "misc4";
    case SDL_GAMEPAD_BUTTON_MISC5: return "misc5";
    case SDL_GAMEPAD_BUTTON_MISC6: return "misc6";
    default: return "unknown";
    }
}

static const char *axis_name(Uint8 axis)
{
    switch ((SDL_GamepadAxis)axis) {
    case SDL_GAMEPAD_AXIS_LEFTX: return "leftx";
    case SDL_GAMEPAD_AXIS_LEFTY: return "lefty";
    case SDL_GAMEPAD_AXIS_RIGHTX: return "rightx";
    case SDL_GAMEPAD_AXIS_RIGHTY: return "righty";
    case SDL_GAMEPAD_AXIS_LEFT_TRIGGER: return "left_trigger";
    case SDL_GAMEPAD_AXIS_RIGHT_TRIGGER: return "right_trigger";
    default: return "unknown";
    }
}

int main(int argc, char **argv)
{
    int seconds = 30;

    if (argc > 1) {
        seconds = SDL_atoi(argv[1]);
        if (seconds <= 0) {
            seconds = 30;
        }
    }

    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_FLYDIGI, "1");

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD | SDL_INIT_EVENTS)) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    int count = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&count);
    printf("gamepads=%d\n", count);

    SDL_Gamepad *gamepads[16] = { 0 };
    int opened = 0;
    for (int i = 0; ids && i < count && opened < 16; ++i) {
        SDL_Gamepad *pad = SDL_OpenGamepad(ids[i]);
        if (!pad) {
            printf("open id=%u failed: %s\n", (unsigned)ids[i], SDL_GetError());
            continue;
        }
        gamepads[opened++] = pad;
        printf("opened id=%u name=%s path=%s vendor=%04x product=%04x buttons=%d axes=%d\n",
               (unsigned)ids[i],
               SDL_GetGamepadName(pad) ? SDL_GetGamepadName(pad) : "",
               SDL_GetGamepadPath(pad) ? SDL_GetGamepadPath(pad) : "",
               SDL_GetGamepadVendor(pad),
               SDL_GetGamepadProduct(pad),
               SDL_GAMEPAD_BUTTON_COUNT,
               SDL_GAMEPAD_AXIS_COUNT);
    }
    SDL_free(ids);

    Uint64 end = SDL_GetTicks() + (Uint64)seconds * 1000;
    printf("listening=%d seconds\n", seconds);
    fflush(stdout);

    while (SDL_GetTicks() < end) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            switch (event.type) {
            case SDL_EVENT_GAMEPAD_ADDED:
                printf("added id=%u\n", (unsigned)event.gdevice.which);
                break;
            case SDL_EVENT_GAMEPAD_REMOVED:
                printf("removed id=%u\n", (unsigned)event.gdevice.which);
                break;
            case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
            case SDL_EVENT_GAMEPAD_BUTTON_UP:
                printf("button %-13s %s\n",
                       button_name(event.gbutton.button),
                       event.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN ? "down" : "up");
                break;
            case SDL_EVENT_GAMEPAD_AXIS_MOTION:
                if (event.gaxis.value < -8000 || event.gaxis.value > 8000) {
                    printf("axis %-13s %d\n", axis_name(event.gaxis.axis), event.gaxis.value);
                }
                break;
            default:
                break;
            }
        }
        SDL_Delay(10);
    }

    for (int i = 0; i < opened; ++i) {
        SDL_CloseGamepad(gamepads[i]);
    }
    SDL_Quit();
    return 0;
}

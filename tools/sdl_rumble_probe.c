#include <SDL3/SDL.h>

#include <inttypes.h>
#include <stdio.h>

static const char *gamepad_type_name(SDL_GamepadType type)
{
    switch (type) {
    case SDL_GAMEPAD_TYPE_UNKNOWN:
        return "unknown";
    case SDL_GAMEPAD_TYPE_STANDARD:
        return "standard";
    case SDL_GAMEPAD_TYPE_XBOX360:
        return "xbox360";
    case SDL_GAMEPAD_TYPE_XBOXONE:
        return "xboxone";
    case SDL_GAMEPAD_TYPE_PS3:
        return "ps3";
    case SDL_GAMEPAD_TYPE_PS4:
        return "ps4";
    case SDL_GAMEPAD_TYPE_PS5:
        return "ps5";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO:
        return "switch-pro";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT:
        return "switch-joycon-left";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT:
        return "switch-joycon-right";
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR:
        return "switch-joycon-pair";
    case SDL_GAMEPAD_TYPE_GAMECUBE:
        return "gamecube";
    case SDL_GAMEPAD_TYPE_STEAM:
        return "steam";
    default:
        return "invalid";
    }
}

static void print_gamepad_info(SDL_Gamepad *pad)
{
    SDL_PropertiesID props = SDL_GetGamepadProperties(pad);
    char *mapping = SDL_GetGamepadMapping(pad);

    printf("type=%s real_type=%s steam_handle=0x%016" PRIx64 "\n",
           gamepad_type_name(SDL_GetGamepadType(pad)),
           gamepad_type_name(SDL_GetRealGamepadType(pad)),
           SDL_GetGamepadSteamHandle(pad));
    printf("cap.rumble=%s cap.trigger_rumble=%s\n",
           SDL_GetBooleanProperty(props, SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN, false) ? "true" : "false",
           SDL_GetBooleanProperty(props, SDL_PROP_GAMEPAD_CAP_TRIGGER_RUMBLE_BOOLEAN, false) ? "true" : "false");
    printf("mapping=%s\n", mapping ? mapping : "(none)");
    SDL_free(mapping);
}

static void delay_with_events(Uint32 ms)
{
    const Uint64 end = SDL_GetTicks() + ms;

    while (SDL_GetTicks() < end) {
        SDL_Event event;

        while (SDL_PollEvent(&event)) {
        }
        SDL_Delay(10);
    }
}

static bool pulse_normal(SDL_Gamepad *pad, Uint16 left, Uint16 right, const char *label)
{
    printf("%s: SDL_RumbleGamepad(left=%u right=%u)\n", label, left, right);
    fflush(stdout);
    if (!SDL_RumbleGamepad(pad, left, right, 900)) {
        fprintf(stderr, "SDL_RumbleGamepad failed: %s\n", SDL_GetError());
        return false;
    }
    delay_with_events(1200);
    SDL_RumbleGamepad(pad, 0, 0, 0);
    delay_with_events(500);
    return true;
}

static bool pulse_triggers(SDL_Gamepad *pad, Uint16 left, Uint16 right, const char *label)
{
    printf("%s: SDL_RumbleGamepadTriggers(left=%u right=%u)\n", label, left, right);
    fflush(stdout);
    if (!SDL_RumbleGamepadTriggers(pad, left, right, 900)) {
        fprintf(stderr, "SDL_RumbleGamepadTriggers failed: %s\n", SDL_GetError());
        return false;
    }
    delay_with_events(1200);
    SDL_RumbleGamepadTriggers(pad, 0, 0, 0);
    delay_with_events(500);
    return true;
}

int main(void)
{
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_FLYDIGI, "1");

    if (!SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD | SDL_INIT_EVENTS)) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    int count = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&count);
    SDL_Gamepad *pad = NULL;

    printf("gamepads=%d\n", count);
    for (int i = 0; ids && i < count; ++i) {
        SDL_Gamepad *candidate = SDL_OpenGamepad(ids[i]);

        if (!candidate) {
            printf("open id=%u failed: %s\n", (unsigned)ids[i], SDL_GetError());
            continue;
        }

        printf("opened id=%u name=%s vendor=%04x product=%04x path=%s\n",
               (unsigned)ids[i],
               SDL_GetGamepadName(candidate) ? SDL_GetGamepadName(candidate) : "",
               SDL_GetGamepadVendor(candidate),
               SDL_GetGamepadProduct(candidate),
               SDL_GetGamepadPath(candidate) ? SDL_GetGamepadPath(candidate) : "");

        if (SDL_GetGamepadVendor(candidate) == 0x37d7 &&
            SDL_GetGamepadProduct(candidate) == 0x2401) {
            pad = candidate;
            break;
        }

        SDL_CloseGamepad(candidate);
    }
    SDL_free(ids);

    if (!pad) {
        fprintf(stderr, "Flydigi Vader 5 Pro 37d7:2401 not found\n");
        SDL_Quit();
        return 1;
    }

    print_gamepad_info(pad);
    printf("Report which motors move for each pulse.\n");

    pulse_normal(pad, 0xffff, 0x0000, "normal left");
    pulse_normal(pad, 0x0000, 0xffff, "normal right");
    pulse_triggers(pad, 0xffff, 0x0000, "trigger left");
    pulse_triggers(pad, 0x0000, 0xffff, "trigger right");
    pulse_normal(pad, 0xffff, 0xffff, "normal both");
    pulse_triggers(pad, 0xffff, 0xffff, "trigger both");

    SDL_RumbleGamepad(pad, 0, 0, 0);
    SDL_RumbleGamepadTriggers(pad, 0, 0, 0);
    SDL_CloseGamepad(pad);
    SDL_Quit();
    return 0;
}

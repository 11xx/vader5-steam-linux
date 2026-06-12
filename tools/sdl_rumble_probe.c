#include <SDL3/SDL.h>

#include <stdio.h>

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

    printf("mirror hint=%s\n",
           SDL_GetHint("SDL_JOYSTICK_HIDAPI_FLYDIGI_VADER5_MIRROR_RUMBLE") ?
           SDL_GetHint("SDL_JOYSTICK_HIDAPI_FLYDIGI_VADER5_MIRROR_RUMBLE") : "(default)");
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

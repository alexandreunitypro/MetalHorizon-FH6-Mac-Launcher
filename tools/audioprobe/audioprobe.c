/* audioprobe: plays a short tone on each speaker of a multichannel WASAPI shared-mode stream, one speaker after
 * the other, the way Forza Horizon 6's XAudio2 mastering voice (7.1 float, mask 0x63f) and its spatial audio bed
 * (7.1.4, mask 0x2d63f) reach mmdevapi. On a 2-channel Mac without Highball's patch 0023, only the first two tones
 * (front left, front right) are heard: everything in the other channels, most of the engine sound included, is lost.
 * Usage: audioprobe.exe [mask-in-hex, default 63f] [seconds-per-tone, default 1]
 * Build: x86_64-w64-mingw32-clang -O2 -o audioprobe.exe audioprobe.c -lole32 -luuid */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>

static const GUID float_subtype = { 0x00000003, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
static const struct { DWORD bit; const char *name; } speakers[] = {
    { SPEAKER_FRONT_LEFT, "front left" }, { SPEAKER_FRONT_RIGHT, "front right" },
    { SPEAKER_FRONT_CENTER, "front centre" }, { SPEAKER_LOW_FREQUENCY, "LFE (subwoofer)" },
    { SPEAKER_BACK_LEFT, "back left" }, { SPEAKER_BACK_RIGHT, "back right" },
    { SPEAKER_FRONT_LEFT_OF_CENTER, "front left of centre" }, { SPEAKER_FRONT_RIGHT_OF_CENTER, "front right of centre" },
    { SPEAKER_BACK_CENTER, "back centre" }, { SPEAKER_SIDE_LEFT, "side left" }, { SPEAKER_SIDE_RIGHT, "side right" },
    { SPEAKER_TOP_CENTER, "top centre" }, { SPEAKER_TOP_FRONT_LEFT, "top front left" },
    { SPEAKER_TOP_FRONT_CENTER, "top front centre" }, { SPEAKER_TOP_FRONT_RIGHT, "top front right" },
    { SPEAKER_TOP_BACK_LEFT, "top back left" }, { SPEAKER_TOP_BACK_CENTER, "top back centre" },
    { SPEAKER_TOP_BACK_RIGHT, "top back right" },
};

int main(int argc, char **argv)
{
    DWORD mask = argc > 1 ? strtoul(argv[1], NULL, 16) : 0x63f;
    double secs = argc > 2 ? atof(argv[2]) : 1.0;
    IMMDeviceEnumerator *mme; IMMDevice *dev; IAudioClient *ac; IAudioRenderClient *rc;
    WAVEFORMATEX *mix; WAVEFORMATEXTENSIBLE fmt = {0};
    UINT32 bufframes, pad, chans = 0, done_frames = 0, total, i, k;
    const char *names[32]; HRESULT hr; double phase = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    for (i = 0; i < sizeof(speakers) / sizeof(speakers[0]); i++) if (mask & speakers[i].bit) names[chans++] = speakers[i].name;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&mme);
    if (FAILED(hr)) { printf("RESULT enumerator failed %#lx\n", hr); return 1; }
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(mme, eRender, eConsole, &dev);
    if (FAILED(hr)) { printf("RESULT no default render device %#lx\n", hr); return 1; }
    IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&ac);
    IAudioClient_GetMixFormat(ac, &mix);
    printf("device mix format: %u channels, %lu Hz, mask %#lx\n", mix->nChannels, mix->nSamplesPerSec,
           mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE ? ((WAVEFORMATEXTENSIBLE *)mix)->dwChannelMask : 0);

    fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    fmt.Format.nChannels = chans;
    fmt.Format.nSamplesPerSec = 48000;
    fmt.Format.wBitsPerSample = 32;
    fmt.Format.nBlockAlign = chans * 4;
    fmt.Format.nAvgBytesPerSec = 48000 * fmt.Format.nBlockAlign;
    fmt.Format.cbSize = sizeof(fmt) - sizeof(WAVEFORMATEX);
    fmt.Samples.wValidBitsPerSample = 32;
    fmt.dwChannelMask = mask;
    fmt.SubFormat = float_subtype;
    hr = IAudioClient_Initialize(ac, AUDCLNT_SHAREMODE_SHARED, 0, 2000000, 0, &fmt.Format, NULL);
    if (FAILED(hr))
        hr = IAudioClient_Initialize(ac, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                                     | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, 2000000, 0, &fmt.Format, NULL);
    printf("stream: %u channels, mask %#lx, float 48000 Hz -> Initialize %#lx\n", chans, mask, hr);
    if (FAILED(hr)) { printf("RESULT stream refused\n"); return 1; }
    IAudioClient_GetBufferSize(ac, &bufframes);
    IAudioClient_GetService(ac, &IID_IAudioRenderClient, (void **)&rc);
    IAudioClient_Start(ac);

    total = (UINT32)(secs * 48000);
    for (k = 0; k < chans; k++)
    {
        printf("tone %u/%u: %s\n", k + 1, chans, names[k]);
        done_frames = 0;
        while (done_frames < total)
        {
            UINT32 n; BYTE *data; float *f;
            IAudioClient_GetCurrentPadding(ac, &pad);
            n = min(bufframes - pad, total - done_frames);
            if (!n) { Sleep(5); continue; }
            if (FAILED(IAudioRenderClient_GetBuffer(rc, n, &data))) { Sleep(5); continue; }
            f = (float *)data;
            for (i = 0; i < n; i++)
            {
                UINT32 j, pos = done_frames + i;
                /* 440 Hz (110 Hz on the LFE), 20 ms fades so the speaker switch does not click */
                float env = (float)min(1.0, min(pos, total - pos) / 960.0);
                float s = 0.25f * env * (float)sin(phase);
                phase += 2 * 3.14159265358979 * (mask & SPEAKER_LOW_FREQUENCY && !strcmp(names[k], "LFE (subwoofer)") ? 110 : 440) / 48000;
                for (j = 0; j < chans; j++) f[i * chans + j] = j == k ? s : 0.0f;
            }
            IAudioRenderClient_ReleaseBuffer(rc, n, 0);
            done_frames += n;
        }
    }
    do { Sleep(20); IAudioClient_GetCurrentPadding(ac, &pad); } while (pad);
    IAudioClient_Stop(ac);
    printf("RESULT played %u tones; count how many you heard\n", chans);
    return 0;
}

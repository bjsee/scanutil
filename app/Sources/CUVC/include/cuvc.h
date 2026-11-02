#ifndef CUVC_H
#define CUVC_H

// Liest und setzt UVC-Controls des CZUR ET24 Pro (04fc:6333) über IOKit.
// Rückgabe 0 bei Erfolg, sonst ein IOReturn-Wert oder -1 (Gerät nicht gefunden).
// Quelle des Vorgehens: prototype/uvc_controls.c, Dokumentation: docs/hardware-access.adoc.

int cuvc_get_sharpness(int *value, int *min, int *max, int *def);
int cuvc_set_sharpness(int value);

#endif

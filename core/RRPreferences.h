#ifndef RR_PREFERENCES_H
#define RR_PREFERENCES_H

#define RR_PREFERENCES_DOMAIN "com.kleinersource.randomring"
#define RR_PREFERENCES_PATH "/var/mobile/Library/Preferences/" RR_PREFERENCES_DOMAIN ".plist"

#define RR_PREFERENCE_ENABLED_KEY @"enabled"
/* Global pool, used in global mode and whenever a call's SIM slot is unknown. */
#define RR_PREFERENCE_SELECTED_TONE_IDS_KEY @"selectedToneIDs"
/* When true and two SIMs are in use, each SIM draws from its own pool. */
#define RR_PREFERENCE_PER_SIM_KEY @"perSIMEnabled"
#define RR_PREFERENCE_SIM1_TONE_IDS_KEY @"selectedToneIDsSIM1"
#define RR_PREFERENCE_SIM2_TONE_IDS_KEY @"selectedToneIDsSIM2"
/* Written by the Settings pane: subscription/account UUID string -> slot number (1 or 2). */
#define RR_PREFERENCE_SIM_ACCOUNTS_KEY @"simAccounts"

#endif

NEXGRAB v3.2  -  by WSNex
=============================================

Ek hi project se dono banti hain:
  - Windows EXE  (PC app)
  - Android APK  (phone app)


NEXGRAB (pehle naam: RSK Futuristic Downloader)
-----------------------------------------------
Naya naam + naya logo. Phone par nayi APK purani "RSK Downloader" app ke UPAR
update ho jati hai (settings, history same rehti hain). PC app bhi purani settings
khud le aati hai.


SAB SE ASAAN TAREEQA  (GUI)
---------------------------
1. ZIP ko L: drive (ya jahan jagah ho) par extract karein.
2. "NexGrab Builder.bat" double-click karein.
   Pehli dafa 1-2 minute setup (chhota Python env), phir hamesha seedha GUI khulta hai.
   (EXE ki jagah .bat is liye: Windows Defender unsigned EXE builders ko aksar ghalti se
    virus samajh kar delete kar deta hai. .bat + Python ke saath ye masla nahi hota.)
3. APK / EXE / DONO chunein -> BUILD dabayein.
   - Live progress bar, har step ka status, timer aur live log nazar aata hai.
   - "Pehle Flutter + libraries update karo" ON ho to din mein ek dafa khud:
       flutter upgrade, Dart packages upgrade, yt-dlp Android library ka naya patch.
   - Gradle / Flutter cache khud L: (ya sab se zyada jagah wali drive) par rakhta hai,
     C: nahi bharti.
   - STOP button se kabhi bhi rok sakte hain.
   - "C: saaf karo" button = NexGrab_FREE_SPACE.bat (C: ka kachra saaf + cache L: par).
4. Build khatam hote hi OUTPUT folder khud khul jata hai:

   OUTPUT\Android\NexGrab_v3.2.apk         (aaj kal ke sab phones)
   OUTPUT\Android\NexGrab_v3.2_32bit.apk   (sirf purane 32-bit phone)
   OUTPUT\Windows\NexGrab\NexGrab.exe
   OUTPUT\Windows\NexGrab_v3.2_Windows.zip   (share karne ke liye)
   OUTPUT\logs\                             (har build ka poora log)

Purana tareeqa bhi chalta hai: BUILD_ALL.bat (console, 1/2/3 number).

Pehli dafa internet ON rakhein (packages download hote hain).


KYA CHAHIYE
-----------
EXE ke liye : Python 3.10+ python.org wala (na ho to builder winget se install karne ki koshish karta hai)
APK ke liye : Aapka INSTALLED Flutter. Builder Flutter dobara download NAHI karta.
              Java 17 aur Android SDK (Android Studio ke baghair) khud set ho jate hain.

KAUN SI SITES? (PC aur PHONE dono)
-----------------------------------
Dono apps ab ek hi engine use karti hain: yt-dlp (1000+ websites).
  YouTube (video, Shorts, playlist), Instagram (reels/posts), Facebook, TikTok,
  X/Twitter, Vimeo, Dailymotion, Reddit, SoundCloud ... aur direct .mp4/.mp3 links.
Phone par:
  - Link paste/share karein -> "ANALYZE LINK" -> quality chunein (Best / 1080p / 720p / MP3 ...).
  - Poori playlist chahiye to "Poori playlist / channel" tick karein.
  - Files Downloads/NexGrab mein save hoti hain.
  - Settings -> Engine: "Update" dabane se yt-dlp naya ho jata hai (sites badalti rehti hain;
    app khud bhi har 3 din baad update karti hai).
  - Instagram/Facebook private ya login wali post: Settings -> Cookies -> cookies.txt chunein.
Pehli dafa app kholne par engine set hone mein 10-20 second lagte hain (sirf ek baar).
APK ab ~70-80 MB hai kyun ke is mein Python + yt-dlp + ffmpeg shamil hain.


APK: PEHLI BUILD vs AGLI BUILDS
-------------------------------
Pehli dafa Gradle + Flutter engine + yt-dlp library download hoti hain (15-25 min, internet par depend).
Android SDK na ho to ~150 MB command-line tools + SDK packages bhi.
Agli builds 1-3 minute.
Purana builder 1 GB Flutter zip PowerShell se leta tha ("bytes written" sari raat) - woh ab khatam.
Purani ".tools\flutter_stable.zip" khud delete ho jati hai. ".tools\flutter" folder bhi
delete kar sakte hain agar aap ka apna Flutter install hai.


ZAROORI: EXE KE SAATH "tools" FOLDER
------------------------------------
"NexGrab.exe" ke saath "tools" folder hota hai:
   tools\ffmpeg.exe   -> HD video + audio merge, MP3
   tools\deno.exe     -> YouTube ke liye zaroori
EXE aur tools folder hamesha saath rakhein / saath share karein (zip yahi karta hai).
Agar sirf EXE kahin copy ho jaye to app Settings -> "Install missing tools" se khud le aati hai.


TOR (PC aur phone dono par)
---------------------------
TOR ON/OFF SWITCH:
  PC    : left sidebar ke neeche "TOR" switch.
  Phone : Home par link box ke neeche "TOR" switch.
  ON  = Tor Browser / Orbot chal raha ho to Tor se download, warna Direct.
  OFF = hamesha Direct (Tor khula ho tab bhi).
  Switch ke neeche likha hota hai: "Tor connected" (hara) ya "Tor Browser/Orbot kholein" (peela).

Detail: Network mein "Auto" default hai:
  PC    : Tor Browser kholein, connect hone dein, link paste karein -> download Tor se.
  Phone : Orbot kholein, Start dabayein, link paste karein -> download Tor se.
Tor band ho to Auto khud Direct use karta hai.
Sirf Tor chahiye (kabhi Direct nahi)? Network -> "Tor only".
Note: YouTube aksar Tor ko block karta hai. PC aur phone dono Auto mode mein bot-check aane par
khud Direct se dobara try karte hain ("Tor only" mode mein nahi).


YOUTUBE "Sign in to confirm you're not a bot"
---------------------------------------------
Ye YouTube ki taraf se IP check hai.
1. Tor/VPN on hai to: Network -> Direct (ya Auto - woh khud Direct try karega).
2. Direct par bhi aaye to cookies dein (PC; phone par Settings -> Cookies -> cookies.txt):
   - Firefox mein YouTube login karein -> app mein Cookies: Firefox  (Firefox band kar dein)
   - ya Chrome extension "Get cookies.txt LOCALLY" se youtube.com ki cookies.txt export karein
     -> app mein Cookies: "cookies.txt file..." -> file chunein.
   Chrome ki apni cookies Windows par yt-dlp parh nahi sakta (Chrome encryption), is liye
   "Chrome" option aksar kaam nahi karta.


FOLDERS
-------
NexGrab Builder.bat  <- yahi chalayein (GUI)
BUILD_ALL.bat        <- console wala builder
NexGrab_FREE_SPACE.bat <- C: drive saaf karo
builder\              <- NexGrab Builder ka code (rsk_builder.py) + .venv (khud banta hai)
README.txt
AUDIT_REPORT.md      <- purane code mein kya ghalat tha aur kya theek kiya
pc\                  <- Windows app (Python)
   rsk_futuristic_downloader.py   UI
   rsk_core.py                     download engine (yt-dlp, Tor, proxy, tunnel)
   build_exe.bat                   sirf EXE banane ke liye
   run_app.bat                     bina EXE banaye seedha chalane ke liye
   server_setup_ubuntu.sh          Private tunnel ke VPS ke liye
android\             <- Android app (Flutter)
   MAKE_APK.cmd                    sirf APK banane ke liye
   android_template\               (delete NA karein)


PURANI SETTINGS
---------------
v2.x ki settings aur history khud naye version mein aa jati hain.

Sirf woh content download karein jis ka aap ko haq / ijazat ho.

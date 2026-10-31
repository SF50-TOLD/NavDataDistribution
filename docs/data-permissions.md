# Permission to use European AIP data

The nav-data generator reads official aeronautical data sets and extracts a few facts per
runway end (threshold position and elevation, declared distances, dimensions, surface, glidepath
angle, threshold crossing height) and per obstacle (position, height). It never re-hosts the
source files. It writes those facts, merged with other sources, into its own property-list schema,
which users of the free SF50 TOLD app download and cache offline.

This document lists the European providers whose terms forbid that use without written
permission, quotes the clause that does so, and drafts the request to send. It is research, not
legal advice; have a lawyer in the relevant jurisdiction review it before relying on it.

## Why derived use still needs permission

Each restrictive notice protects the *information*, not the files, so converting AIXM into our
own schema does not take the data out of scope. The EU database right reaches the same result
independently of copyright:

> "'extraction' shall mean the permanent or temporary transfer of all or a substantial part of
> the contents of a database to another medium by any means or in any form"
> — Directive 96/9/EC, art. 7(2)(a)
>
> "'re-utilization' shall mean any form of making available to the public all or a substantial
> part of the contents of a database by the distribution of copies, by renting, by on-line or
> other forms of transmission"
> — Directive 96/9/EC, art. 7(2)(b)

The CJEU has held that rearranging or selecting the data does not prevent a transfer from being
extraction (*Directmedia*, C-304/07), and that serving data to users in a member state is
re-utilisation there even from a server elsewhere (*Football Dataco v Sportradar*, C-173/11).
Facts themselves are not copyrightable, but the database right protects the investment in
collecting and verifying them.

Two limits work in our favour where they apply:

- A lawful user may always extract insubstantial parts, and contract terms to the contrary are
  void (arts. 8(1) and 15). Taking every runway in a country is not insubstantial.
- Public-sector bodies may not use the database right to restrict re-use beyond the Open Data
  Directive (EU) 2019/1024, art. 1(6). Most of these providers are state-owned companies that
  argue their AIS work is commercial, which takes them outside that directive.

## The request

Send each provider the same core request, adjusted by the notes in its section.

> Subject: Permission to use derived AIP data in a free flight-planning app
>
> I develop SF50 TOLD, a free iOS takeoff and landing performance calculator for the Cirrus SF50
> (no purchase, no advertising, no subscription). I would like to include data from your
> [data set names] in the app's airport database.
>
> The app would not redistribute your files. Each AIRAC cycle, our generator would extract the
> following fields, convert them into our own database format, and merge them with other
> sources: [field list]. App users download that database and keep it on their devices for
> offline use. The app is a planning aid, not a source of navigation, and directs pilots to the
> official AIP.
>
> I am asking for a non-exclusive, royalty-free permission to extract those fields every cycle,
> store them in our database, and make the database available to the public through the app,
> worldwide. Please let me know what attribution and disclaimer wording you require, and whether
> any other conditions apply.
>
> For comparison, UK AIP GEN 0.1 §5.4 acknowledges third parties that "process data using
> information sourced from official UK Aeronautical Information Products, and who then make this
> information available to users within their own products and services (with or without
> charge)."

Field list for runway data: threshold coordinates and elevation, displaced threshold length,
TORA, TODA, ASDA, LDA, runway length, width and surface, glidepath angle and reference datum
height. Field list for obstacle data: position, top elevation, height above ground.

## Providers that need written permission

### Germany — DFS Deutsche Flugsicherung

- **Data sets:** AIP data set (ED_Runway, ED_AirportHeliport, ED_Navaids), Area 1 obstacles.
- **Access:** free, no registration, via `https://aip.dfs.de/datasets/rest/`.
- **Contact:** `data@dfs.de` (from the DFS data set REST API documentation).

The notice on <https://aip.dfs.de/datasets/> and in every file's metadata:

> "All material, publications, information and data (AIS Products) published by the
> Aeronautical Information Services of Germany (DFS Deutsche Flugsicherung GmbH) are the subject
> of copyright. This specifically includes all elements of the aeronautical information products.
> Unless specified otherwise, AIS Products may be used for aviation purposes only by the
> organisation to which they were issued. Except as permitted above, no part of the AIS
> Publications may be reproduced, stored in a retrieval system, transmitted, redistributed,
> republished or commercially exploited in any way without the prior written permission of the
> Aeronautical Information Services of Germany (DFS Deutsche Flugsicherung GmbH)."

**Reaches derived data:** yes. The protected object is "information and data", and "no part …
stored in a retrieval system … in any way" describes our database exactly. The AIS-Portal terms
(<https://ais.dfs.de/pilotservice/service/information/disclaimer/disclaimer.jsp>, §2) permit
automated retrieval of "AIXM download data" but not onward distribution.

**Also ask:**

- whether someone who downloads anonymously from the REST service is "the organisation to which
  they were issued";
- whether a performance and planning tool counts as an "aviation purpose".

German copyright law exempts official works (UrhG §5), and the BGH has said that exemption
applies by analogy to databases (*Sächsischer Ausschreibungsdienst*, I ZR 261/03). DFS has stated,
in a document released under a freedom-of-information request, that producing the AIP is not a
sovereign task, and the BGH reads §5 narrowly (*Bodenrichtwertsammlung*, I ZR 185/03). Raise the
argument if useful; don't rely on it.

### Spain — ENAIRE

- **Data sets:** per-aerodrome AIP data sets (`LE_Amdt_*_AIP_DS_FULL_<ICAO>.xml`) and obstacles.
- **Access:** free, no registration, from <https://aip.enaire.es/AIP/DatosDigitales-en.html>.
- **Contact:** `ais@enaire.es` (AIP España GEN 0.1 and GEN 3.1).

The data sets carry no licence of their own. The site-wide legal notice
(<https://www.enaire.es/aviso_legal>, §6):

> "Cualquier reproducción, transmisión, adaptación, traducción, modificación, comunicación al
> público, o cualquier otra explotación de todo o parte del contenido de este sitio, efectuada de
> cualquier forma o por cualquier medio, electrónico, mecánico u otro, están estrictamente
> prohibidos salvo autorización previa por escrito de ENAIRE."

**Reaches derived data:** yes, if it applies: "adaptación … modificación … de cualquier forma"
covers transformation. It is a generic website notice, though, and Spain's re-use law may
override it.

**Frame the request** as a *solicitud de reutilización* under Ley 37/2007, art. 10, and ask
under which licence the AIXM data sets may be re-used. Art. 4.4 bars covered public bodies from
using the database right to restrict re-use, and art. 4.2 requires any conditions to be
objective, proportionate and justified. Whether ENAIRE, an *entidad pública empresarial*, falls
under art. 2(b) is unresolved.

### Denmark — Danish Civil Aviation and Railway Authority

- **Data sets:** none found published; ask what exists.
- **Contact:** Trafikstyrelsen, `info@trafikstyrelsen.dk` (AIP Denmark GEN 1.1). The permission
  must come from the authority, not from Naviair, which publishes the AIP on its behalf.

AIP Denmark GEN 0.1 §6 (<https://aim.naviair.dk/media/files/ytcvmgddbl1/EK_GEN_0_1_en.pdf>):

> "As certain information in the publications are the property of the Danish CAA and/or third
> parties, no part may be reproduced except as authorized by written permission from the Danish
> CAA. This restriction extends to all types of media in which the information may be embodied."

**Reaches derived data:** yes. The object is "the information", in "all types of media".

### Poland — PANSA

- **Data sets:** AIP data set (AIXM 5.1), Area 1 and 2 obstacles.
- **Access:** subscribers only, by order form at
  <https://www.ais.pansa.pl/form/order/orderform_en.htm>.
- **Contact:** `ais.poland@pansa.pl` (AIS Poland contact page).

Copyright policy (<https://ais.pansa.pl/en/publications/copyright-policy/>):

> "The AIS products can only be used by downloading, displaying or printing them (unchanged) for
> operational purposes by entities defined in item 2.2 of ICAO Annex 15. The use of AIS products
> in another form or for other purposes, in particular for commercial purposes, is subject to
> PANSA's permission."

**Reaches derived data:** yes, most explicitly of all: use must be "unchanged", and "another
form" needs permission. A subscription also forms a contract, so the terms bind regardless of
the database right.

**Ask for** subscription terms together with permission for use "in another form".

### Norway — Avinor

- **Data sets:** no public aerodrome data set found; obstacle data sets are free at
  <https://aim-prod.avinor.no/en/Obstacle>.
- **Contact:** `aim@avinor.no` (Avinor AIS page).

AIP Norway GEN 0.1 §5:

> "This publication, with all its parts, is subject to copyright. Any use of it outside the law
> applying to copyright is inadmissible without permission from Avinor AS and will be prosecuted
> according to civil law."

**Reaches derived data:** only as far as the Copyright Act does. Norway's act applies its
official-works exemption to databases (åndsverkloven §24, referring to §14) and makes contracts
that widen database rights in a published database unenforceable. The open question is whether
Avinor AS counts as a public authority.

**Ask** whether an aerodrome data set is available and on what terms, and confirm that derived
runway and obstacle fields may be used in the app.

### Czech Republic — ANS CR

- **Data sets:** obstacle and terrain data sets (AIXM 5.1), on request only; no AIP data set
  listed.
- **Contact:** `ais@ans.cz` for data sets (AIP Czech Republic GEN 3.1).
- **Terms:** not yet reviewed; request the terms with the data.

### Netherlands — LVNL, and Belgium — skeyes

Their sites refused automated requests, so data set availability and terms are unverified.
Check by hand before writing.

## Sources used with confirmation recommended

These are in use. Their terms appear to allow it for a free app, but written confirmation
removes doubt.

### United Kingdom — NATS

- **Used:** AIP data set and Area 1 obstacles (AIXM 5.1).
- **Terms:** GEN 3.1 §6.7, "The datasets are for Aviation Use Only"; file metadata, "Not for
  resale". GEN 0.1 §5.4 acknowledges derived products "with or without charge", and §5.5 makes
  re-packagers liable for their modifications.
- **Confirm:** that a free app counts as aviation use and not resale.

### Austria — Austro Control

- **Used:** Area 1 obstacles (AIXM 5.1.1).
- **Contact:** `aim.sdm@austrocontrol.at` (AIP Austria GEN 3.1, responsible for digital data
  sets).
- **Terms:** AIP Austria GEN 0.1 §5.1 (German text): "Jede gewerbliche – auch teilweise –
  Reproduktion, Verarbeitung, Verwendung etc. der Inhalte … ist ohne vorherige ausdrückliche
  schriftliche Zustimmung der ACG untersagt". The SDI disclaimer: "Commercial use of the online
  chart shown here and/or data contained therein is only allowed with authorization from Austro
  Control."
- **Confirm:** that free, unmonetised use is not *gewerbliche* use.

## Open questions

- **Regulation:** UK AIP GEN 0.1 §5.4 points to Regulation (EU) 2017/373, Part-DAT, which
  regulates data service providers. Whether a TOLD app's database falls within it is unresearched.
- **France:** SIA publishes its AIXM 4.5 export under the Licence Ouverte, which permits this use,
  but only through a web-shop checkout with no direct download URL. Ask SIA for a stable URL.

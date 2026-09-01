<img src="https://s3.brnbw.com/icon_512px-256pt-2x-p54QrEgUDTIdPSvMdnFu1l7qcKBAlfLHPTA7fd4v7bLiBg1zUNzVFOGznvzOUE33Y7Hq5xDa13c8yYc7byj8AIUzFO9RylggbRjM.png" width="256" height="256" alt="Sprinkles" />

**Customize any website**

Part Mac app, part browser extension. Your CSS and JavaScript.

Watch the introduction on YouTube:

[![YouTube](https://img.youtube.com/vi/rW0Pimms3uE/maxresdefault.jpg)](https://www.youtube.com/watch?v=rW0Pimms3uE)

&rarr; See [getsprinkles.app](https://getsprinkles.app)

## Writing your styles and scripts

Everything lives in two files in your scripts directory: `sprinkles.css` and `sprinkles.js`.
Rules at the top apply everywhere. A marker comment starts a section for one site:

```css
body { font-size: 17px; }          /* every page */

/* @domain example.com */
h1 { font-family: Georgia, serif; }

/* @domain twitter.com, x.com */   /* several sites at once */
/* @domain *.wikipedia.org */      /* a site and its subdomains */
```

`sprinkles.js` uses the same markers with `//` comments. A bare `example.com` also covers
`www.example.com`, and `/* @global */` reopens the everywhere section.

Every section shows up in **Preferences › Sites**, where you can switch one off without
deleting it. Fonts and images saved next to the two files are served from
`https://localhost:3133/files/`, so `src: url("https://localhost:3133/files/YourFont.woff2")`
works from a page.

If you have files from an older Sprinkles — `global.css`, `twitter.com.js` and friends — they
keep working, and Sprinkles offers to combine them for you on launch.

## License

MIT

<img src="https://s3.brnbw.com/Sprinkles_final-copy-3DgD19RTks0vwuMaBkgdc8ZgTbG5lFIQa651VidaDNQbeBI7wcVePIWo2AkjtmLSCTd9GS4vZQGg1ww5EHGZaKRdZKlgRmbXy3xg.png" width="512" alt="Sprinkles" />

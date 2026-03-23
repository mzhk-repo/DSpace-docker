var _paq = window._paq = window._paq || [];

_paq.push(['disableCookies']);
_paq.push(['setDoNotTrack', true]);
_paq.push(['enableSiteSearch', 'query', 'filter']);
_paq.push(['enableLinkTracking']);
_paq.push(['setTrackerUrl', 'https://matomo.pinokew.buzz/js/ping']);
_paq.push(['setSiteId', '2']);
_paq.push(['trackPageView']);

(function () {
  var u = 'https://matomo.pinokew.buzz/';
  var d = document;
  var g = d.createElement('script');
  var s = d.getElementsByTagName('script')[0];

  g.async = true;
  g.src = u + 'matomo.js';
  s.parentNode.insertBefore(g, s);
})();
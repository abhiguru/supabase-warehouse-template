import { createRequire as __createRequire } from 'node:module'; import { Buffer } from 'node:buffer'; const require = __createRequire(import.meta.url);
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
  get: (a, b) => (typeof require !== "undefined" ? require : a)[b]
}) : x)(function(x) {
  if (typeof require !== "undefined") return require.apply(this, arguments);
  throw Error('Dynamic require of "' + x + '" is not supported');
});
var __commonJS = (cb, mod) => function __require2() {
  return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));

// node_modules/ipp/lib/ipputil.js
var require_ipputil = __commonJS({
  "node_modules/ipp/lib/ipputil.js"(exports) {
    function xref(arr) {
      var obj = {};
      arr.forEach(function(item, index) {
        obj[item] = index;
      });
      obj.lookup = arr;
      return obj;
    }
    exports.xref = xref;
    exports.extend = function extend(destination, source) {
      for (var property in source) {
        if (source[property] && source[property].constructor === Object) {
          destination[property] = destination[property] || {};
          extend(destination[property], source[property]);
        } else {
          destination[property] = source[property];
        }
      }
      return destination;
    };
  }
});

// node_modules/ipp/lib/enums.js
var require_enums = __commonJS({
  "node_modules/ipp/lib/enums.js"(exports, module) {
    var xref = require_ipputil().xref;
    var enums = {
      "document-state": xref([
        ,
        ,
        ,
        // 0x00-0x02
        "pending",
        ,
        // 0x04
        "processing",
        ,
        // 0x06
        "canceled",
        // 0x07
        "aborted",
        // 0x08
        "completed"
        // 0x09
      ]),
      "finishings": xref([
        ,
        ,
        ,
        // 0x00 - 0x02
        "none",
        // 0x03 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "staple",
        // 0x04 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "punch",
        // 0x05 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "cover",
        // 0x06 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "bind",
        // 0x07 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "saddle-stitch",
        // 0x08 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "edge-stitch",
        // 0x09 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "fold",
        // 0x0A http://tools.ietf.org/html/rfc2911#section-4.2.6
        "trim",
        // 0x0B ftp://ftp.pwg.org/pub/pwg/ipp/new_VAL/pwg5100.1.pdf
        "bale",
        // 0x0C ftp://ftp.pwg.org/pub/pwg/ipp/new_VAL/pwg5100.1.pdf
        "booklet-maker",
        // 0x0D ftp://ftp.pwg.org/pub/pwg/ipp/new_VAL/pwg5100.1.pdf
        "jog-offset",
        ,
        ,
        ,
        ,
        ,
        // 0x0F - 0x13 reserved for future generic finishing enum values.
        "staple-top-left",
        // 0x14 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "staple-bottom-left",
        // 0x15 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "staple-top-right",
        // 0x16 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "staple-bottom-right",
        // 0x17 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "edge-stitch-left",
        // 0x18 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "edge-stitch-top",
        // 0x19 http://tools.ietf.org/html/rfc2911#section-4.2.6
        "edge-stitch-right",
        // 0x1A http://tools.ietf.org/html/rfc2911#section-4.2.6
        "edge-stitch-bottom",
        // 0x1B http://tools.ietf.org/html/rfc2911#section-4.2.6
        "staple-dual-left",
        // 0x1C http://tools.ietf.org/html/rfc2911#section-4.2.6
        "staple-dual-top",
        // 0x1D http://tools.ietf.org/html/rfc2911#section-4.2.6
        "staple-dual-right",
        // 0x1E http://tools.ietf.org/html/rfc2911#section-4.2.6
        "staple-dual-bottom",
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        // 0x20 - 0x31 reserved for future specific stapling and stitching enum values.
        "bind-left",
        // 0x32 ftp://ftp.pwg.org/pub/pwg/ipp/new_VAL/pwg5100.1.pdf
        "bind-top",
        // 0x33 ftp://ftp.pwg.org/pub/pwg/ipp/new_VAL/pwg5100.1.pdf
        "bind-right",
        // 0x34 ftp://ftp.pwg.org/pub/pwg/ipp/new_VAL/pwg5100.1.pdf
        "bind-bottom",
        ,
        ,
        ,
        ,
        ,
        ,
        // 0x36 - 0x3B
        "trim-after-pages",
        // 0x3C ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext3v10-20120727-5100.13.pdf (IPP Everywhere)
        "trim-after-documents",
        // 0x3D ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext3v10-20120727-5100.13.pdf (IPP Everywhere)
        "trim-after-copies",
        // 0x3E ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext3v10-20120727-5100.13.pdf (IPP Everywhere)
        "trim-after-job"
        // 0x3F ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext3v10-20120727-5100.13.pdf (IPP Everywhere)
      ]),
      "operations-supported": xref([
        ,
        ,
        // 0x01
        "Print-Job",
        // 0x02 http://tools.ietf.org/html/rfc2911#section-3.2.1
        "Print-URI",
        // 0x03 http://tools.ietf.org/html/rfc2911#section-3.2.2
        "Validate-Job",
        // 0x04 http://tools.ietf.org/html/rfc2911#section-3.2.3
        "Create-Job",
        // 0x05 http://tools.ietf.org/html/rfc2911#section-3.2.4
        "Send-Document",
        // 0x06 http://tools.ietf.org/html/rfc2911#section-3.3.1
        "Send-URI",
        // 0x07 http://tools.ietf.org/html/rfc2911#section-3.3.2
        "Cancel-Job",
        // 0x08 http://tools.ietf.org/html/rfc2911#section-3.3.3
        "Get-Job-Attributes",
        // 0x09 http://tools.ietf.org/html/rfc2911#section-3.3.4
        "Get-Jobs",
        // 0x0A http://tools.ietf.org/html/rfc2911#section-3.2.6
        "Get-Printer-Attributes",
        // 0x0B http://tools.ietf.org/html/rfc2911#section-3.2.5
        "Hold-Job",
        // 0x0C http://tools.ietf.org/html/rfc2911#section-3.3.5
        "Release-Job",
        // 0x0D http://tools.ietf.org/html/rfc2911#section-3.3.6
        "Restart-Job",
        ,
        // 0x0F
        "Pause-Printer",
        // 0x10 http://tools.ietf.org/html/rfc2911#section-3.2.7
        "Resume-Printer",
        // 0x11 http://tools.ietf.org/html/rfc2911#section-3.2.8
        "Purge-Jobs",
        // 0x12 http://tools.ietf.org/html/rfc2911#section-3.2.9
        "Set-Printer-Attributes",
        // 0x13 IPP2.1 http://tools.ietf.org/html/rfc3380#section-4.1
        "Set-Job-Attributes",
        // 0x14 IPP2.1 http://tools.ietf.org/html/rfc3380#section-4.2
        "Get-Printer-Supported-Values",
        // 0x15 IPP2.1 http://tools.ietf.org/html/rfc3380#section-4.3
        "Create-Printer-Subscriptions",
        // 0x16 IPP2.1 http://tools.ietf.org/html/rfc3995#section-7.1 && http://tools.ietf.org/html/rfc3995#section-11.1.2
        "Create-Job-Subscription",
        // 0x17 IPP2.1 http://tools.ietf.org/html/rfc3995#section-7.1 && http://tools.ietf.org/html/rfc3995#section-11.1.1
        "Get-Subscription-Attributes",
        // 0x18 IPP2.1 http://tools.ietf.org/html/rfc3995#section-7.1 && http://tools.ietf.org/html/rfc3995#section-11.2.4
        "Get-Subscriptions",
        // 0x19 IPP2.1 http://tools.ietf.org/html/rfc3995#section-7.1 && http://tools.ietf.org/html/rfc3995#section-11.2.5
        "Renew-Subscription",
        // 0x1A IPP2.1 http://tools.ietf.org/html/rfc3995#section-7.1 && http://tools.ietf.org/html/rfc3995#section-11.2.6
        "Cancel-Subscription",
        // 0x1B IPP2.1 http://tools.ietf.org/html/rfc3995#section-7.1 && http://tools.ietf.org/html/rfc3995#section-11.2.7
        "Get-Notifications",
        // 0x1C IPP2.1 IPP2.1 http://tools.ietf.org/html/rfc3996#section-9.2 && http://tools.ietf.org/html/rfc3996#section-5
        "ipp-indp-method",
        // 0x1D did not get standardized
        "Get-Resource-Attributes",
        // 0x1E http://tools.ietf.org/html/draft-ietf-ipp-get-resource-00#section-4.1 did not get standardized
        "Get-Resource-Data",
        // 0x1F http://tools.ietf.org/html/draft-ietf-ipp-get-resource-00#section-4.2 did not get standardized
        "Get-Resources",
        // 0x20 http://tools.ietf.org/html/draft-ietf-ipp-get-resource-00#section-4.3 did not get standardized
        "ipp-install",
        // 0x21 did not get standardized
        "Enable-Printer",
        // 0x22 http://tools.ietf.org/html/rfc3998#section-3.1.1
        "Disable-Printer",
        // 0x23 http://tools.ietf.org/html/rfc3998#section-3.1.2
        "Pause-Printer-After-Current-Job",
        // 0x24 http://tools.ietf.org/html/rfc3998#section-3.2.1
        "Hold-New-Jobs",
        // 0x25 http://tools.ietf.org/html/rfc3998#section-3.3.1
        "Release-Held-New-Jobs",
        // 0x26 http://tools.ietf.org/html/rfc3998#section-3.3.2
        "Deactivate-Printer",
        // 0x27 http://tools.ietf.org/html/rfc3998#section-3.4.1
        "Activate-Printer",
        // 0x28 http://tools.ietf.org/html/rfc3998#section-3.4.2
        "Restart-Printer",
        // 0x29 http://tools.ietf.org/html/rfc3998#section-3.5.1
        "Shutdown-Printer",
        // 0x2A http://tools.ietf.org/html/rfc3998#section-3.5.2
        "Startup-Printer",
        // 0x2B http://tools.ietf.org/html/rfc3998#section-3.5.3
        "Reprocess-Job",
        // 0x2C http://tools.ietf.org/html/rfc3998#section-4.1
        "Cancel-Current-Job",
        // 0x2D http://tools.ietf.org/html/rfc3998#section-4.2
        "Suspend-Current-Job",
        // 0x2E http://tools.ietf.org/html/rfc3998#section-4.3.1
        "Resume-Job",
        // 0x2F http://tools.ietf.org/html/rfc3998#section-4.3.2
        "Promote-Job",
        // 0x30 http://tools.ietf.org/html/rfc3998#section-4.4.1
        "Schedule-Job-After",
        ,
        // 0x32
        "Cancel-Document",
        // 0x33 ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippdocobject10-20031031-5100.5.pdf
        "Get-Document-Attributes",
        // 0x34 ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippdocobject10-20031031-5100.5.pdf
        "Get-Documents",
        // 0x35 ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippdocobject10-20031031-5100.5.pdf
        "Delete-Document",
        // 0x36 ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippdocobject10-20031031-5100.5.pdf
        "Set-Document-Attributes",
        // 0x37 ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippdocobject10-20031031-5100.5.pdf
        "Cancel-Jobs",
        // 0x38 ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext10-20101030-5100.11.pdf
        "Cancel-My-Jobs",
        // 0x39 ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext10-20101030-5100.11.pdf
        "Resubmit-Job",
        // 0x3A ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext10-20101030-5100.11.pdf
        "Close-Job",
        // 0x3B ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext10-20101030-5100.11.pdf
        "Identify-Printer",
        // 0x3C ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext3v10-20120727-5100.13.pdf
        "Validate-Document"
        // 0x3D ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext3v10-20120727-5100.13.pdf
      ]),
      "job-collation-type": xref([
        // IPP2.1 http://tools.ietf.org/html/rfc3381#section-6.3
        "other",
        // 0x01
        "unknown",
        // 0x02
        "uncollated-documents",
        // 0x03
        "collated-documents",
        // 0x04
        "uncollated-documents"
        // 0x05
      ]),
      "job-state": xref([
        ,
        ,
        ,
        // 0x00-0x02
        "pending",
        // 0x03
        "pending-held",
        // 0x04
        "processing",
        // 0x05
        "processing-stopped",
        // 0x06
        "canceled",
        // 0x07
        "aborted",
        // 0x08
        "completed"
        // 0x09
      ]),
      "orientation-requested": xref([
        ,
        ,
        ,
        // 0x00-0x02
        "portrait",
        // 0x03
        "landscape",
        // 0x04
        "reverse-landscape",
        // 0x05
        "reverse-portrait",
        // 0x06
        "none"
        // 0x07 ftp://ftp.pwg.org/pub/pwg/candidates/cs-ippjobprinterext3v10-20120727-5100.13.pdf
      ]),
      "print-quality": xref([
        ,
        ,
        ,
        // 0x00-0x02
        "draft",
        // 0x03
        "normal",
        // 0x04
        "high"
        // 0x05
      ]),
      "printer-state": xref([
        ,
        ,
        ,
        // 0x00-0x02
        "idle",
        // 0x03
        "processing",
        // 0x04
        "stopped"
        // 0x05
      ])
    };
    enums["finishings-default"] = enums.finishings;
    enums["finishings-ready"] = enums.finishings;
    enums["finishings-supported"] = enums.finishings;
    enums["media-source-feed-orientation"] = enums["orientation-requested"];
    enums["orientation-requested-default"] = enums["orientation-requested"];
    enums["orientation-requested-supported"] = enums["orientation-requested"];
    enums["print-quality-default"] = enums["print-quality"];
    enums["print-quality-supported"] = enums["print-quality"];
    module.exports = enums;
  }
});

// node_modules/ipp/lib/status-codes.js
var require_status_codes = __commonJS({
  "node_modules/ipp/lib/status-codes.js"(exports, module) {
    var xref = require_ipputil().xref;
    var status = [];
    status[0] = "successful-ok";
    status[1] = "successful-ok-ignored-or-substituted-attributes";
    status[2] = "successful-ok-conflicting-attributes";
    status[3] = "successful-ok-ignored-subscriptions";
    status[4] = "successful-ok-ignored-notifications";
    status[5] = "successful-ok-too-many-events";
    status[6] = "successful-ok-but-cancel-subscription";
    status[7] = "successful-ok-events-complete";
    status[1024] = "client-error-bad-request";
    status[1025] = "client-error-forbidden";
    status[1026] = "client-error-not-authenticated";
    status[1027] = "client-error-not-authorized";
    status[1028] = "client-error-not-possible";
    status[1029] = "client-error-timeout";
    status[1030] = "client-error-not-found";
    status[1031] = "client-error-gone";
    status[1032] = "client-error-request-entity-too-large";
    status[1033] = "client-error-request-value-too-long";
    status[1034] = "client-error-document-format-not-supported";
    status[1035] = "client-error-attributes-or-values-not-supported";
    status[1036] = "client-error-uri-scheme-not-supported";
    status[1037] = "client-error-charset-not-supported";
    status[1038] = "client-error-conflicting-attributes";
    status[1039] = "client-error-compression-not-supported";
    status[1040] = "client-error-compression-error";
    status[1041] = "client-error-document-format-error";
    status[1042] = "client-error-document-access-error";
    status[1043] = "client-error-attributes-not-settable";
    status[1044] = "client-error-ignored-all-subscriptions";
    status[1045] = "client-error-too-many-subscriptions";
    status[1046] = "client-error-ignored-all-notifications";
    status[1047] = "client-error-client-print-support-file-not-found";
    status[1048] = "client-error-document-password-error";
    status[1049] = "client-error-document-permission-error";
    status[1050] = "client-error-document-security-error";
    status[1051] = "client-error-document-unprintable-error";
    status[1280] = "server-error-internal-error";
    status[1281] = "server-error-operation-not-supported";
    status[1282] = "server-error-service-unavailable";
    status[1283] = "server-error-version-not-supported";
    status[1284] = "server-error-device-error";
    status[1285] = "server-error-temporary-error";
    status[1286] = "server-error-not-accepting-jobs";
    status[1287] = "server-error-busy";
    status[1288] = "server-error-job-canceled";
    status[1289] = "server-error-multiple-document-jobs-not-supported";
    status[1290] = "server-error-printer-is-deactivated";
    status[1291] = "server-error-too-many-jobs";
    status[1292] = "server-error-too-many-documents";
    module.exports = xref(status);
  }
});

// node_modules/ipp/lib/tags.js
var require_tags = __commonJS({
  "node_modules/ipp/lib/tags.js"(exports, module) {
    var xref = require_ipputil().xref;
    var tags = [
      ,
      // 0x00 http://tools.ietf.org/html/rfc2910#section-3.5.1
      "operation-attributes-tag",
      // 0x01 http://tools.ietf.org/html/rfc2910#section-3.5.1
      "job-attributes-tag",
      // 0x02 http://tools.ietf.org/html/rfc2910#section-3.5.1
      "end-of-attributes-tag",
      // 0x03 http://tools.ietf.org/html/rfc2910#section-3.5.1
      "printer-attributes-tag",
      // 0x04 http://tools.ietf.org/html/rfc2910#section-3.5.1
      "unsupported-attributes-tag",
      // 0x05 http://tools.ietf.org/html/rfc2910#section-3.5.1
      "subscription-attributes-tag",
      // 0x06 http://tools.ietf.org/html/rfc3995#section-14
      "event-notification-attributes-tag",
      // 0x07 http://tools.ietf.org/html/rfc3995#section-14
      "resource-attributes-tag",
      // 0x08 http://tools.ietf.org/html/draft-ietf-ipp-get-resource-00#section-11    did not get standardized
      "document-attributes-tag",
      ,
      ,
      ,
      ,
      ,
      ,
      // 0x0A - 0x0F
      "unsupported",
      // 0x10 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "default",
      // 0x11 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "unknown",
      // 0x12 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "no-value",
      ,
      // 0x14
      "not-settable",
      // 0x15 http://tools.ietf.org/html/rfc3380#section-8.1
      "delete-attribute",
      // 0x16 http://tools.ietf.org/html/rfc3380#section-8.2
      "admin-define",
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      // 0x18 - 0x20
      "integer",
      // 0x21 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "boolean",
      // 0x22 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "enum",
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      // 0x24 - 0x2F
      "octetString",
      // 0x30 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "dateTime",
      // 0x31 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "resolution",
      // 0x32 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "rangeOfInteger",
      // 0x33 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "begCollection",
      // 0x34 http://tools.ietf.org/html/rfc3382#section-7.1
      "textWithLanguage",
      // 0x35 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "nameWithLanguage",
      // 0x36 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "endCollection",
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      ,
      // 0x38 - 0x40
      "textWithoutLanguage",
      // 0x41 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "nameWithoutLanguage",
      ,
      // 0x43
      "keyword",
      // 0x44 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "uri",
      // 0x45 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "uriScheme",
      // 0x46 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "charset",
      // 0x47 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "naturalLanguage",
      // 0x48 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "mimeMediaType",
      // 0x49 http://tools.ietf.org/html/rfc2910#section-3.5.2
      "memberAttrName"
      // 0x4A http://tools.ietf.org/html/rfc3382#section-7.1
    ];
    tags[127] = "extension";
    module.exports = xref(tags);
  }
});

// node_modules/ipp/lib/parser.js
var require_parser = __commonJS({
  "node_modules/ipp/lib/parser.js"(exports, module) {
    var enums = require_enums();
    var operations = enums["operations-supported"];
    var statusCodes = require_status_codes();
    var tags = require_tags();
    var RS = "";
    module.exports = function(buf) {
      var obj = {};
      var position = 0;
      var encoding = "utf8";
      function read1() {
        return buf[position++];
      }
      function read2() {
        var val = buf.readInt16BE(position, true);
        position += 2;
        return val;
      }
      function read4() {
        var val = buf.readInt32BE(position, true);
        position += 4;
        return val;
      }
      function read(length, enc) {
        if (length == 0) return "";
        return buf.toString(enc || encoding, position, position += length);
      }
      function readGroups() {
        var group;
        while (position < buf.length && (group = read1()) !== 3) {
          readGroup(group);
        }
      }
      function readGroup(group) {
        var name = tags.lookup[group];
        group = {};
        if (obj[name]) {
          if (!Array.isArray(obj[name]))
            obj[name] = [obj[name]];
          obj[name].push(group);
        } else obj[name] = group;
        while (buf[position] >= 15) {
          readAttr(group);
        }
      }
      function readAttr(group) {
        var tag = read1();
        if (tag === 127) {
          tag = read4();
        }
        var name = read(read2());
        group[name] = readValues(tag, name);
      }
      function hasAdditionalValue() {
        var current = buf[position];
        return current !== 74 && current !== 55 && current !== 3 && buf[position + 1] === 0 && buf[position + 2] === 0;
      }
      function readValues(type, name) {
        var value = readValue(type, name);
        if (hasAdditionalValue()) {
          value = [value];
          do {
            type = read1();
            read2();
            value.push(readValue(type, name));
          } while (hasAdditionalValue());
        }
        return value;
      }
      function readValue(tag, name) {
        var length = read2();
        switch (tag) {
          case tags.enum:
            var val = read4();
            return enums[name] && enums[name].lookup[val] || val;
          case tags.integer:
            return read4();
          case tags.boolean:
            return !!read1();
          case tags.rangeOfInteger:
            return [read4(), read4()];
          case tags.resolution:
            return [read4(), read4(), read1() === 3 ? "dpi" : "dpcm"];
          case tags.dateTime:
            var date2 = new Date(read2(), read1(), read1(), read1(), read1(), read1(), read1());
            return /* @__PURE__ */ new Date(date2.toISOString().substr(0, 23).replace("T", ",") + "," + String.fromCharCode(read(1)) + read(1) + ":" + read(1));
          case tags.textWithLanguage:
          case tags.nameWithLanguage:
            var lang = read(read2());
            var subval = read(read2());
            return lang + RS + subval;
          case tags.nameWithoutLanguage:
          case tags.textWithoutLanguage:
          case tags.octetString:
          case tags.memberAttrName:
            return read(length);
          case tags.keyword:
          case tags.uri:
          case tags.uriScheme:
          case tags.charset:
          case tags.naturalLanguage:
          case tags.mimeMediaType:
            return read(length, "ascii");
          case tags.begCollection:
            read(length);
            return readCollection();
          case tags["no-value"]:
          default:
            debugger;
            return module.exports.handleUnknownTag(tag, name, length, read);
        }
      }
      function readCollection() {
        var tag;
        var collection = {};
        while ((tag = read1()) !== 55) {
          if (tag !== 74) {
            console.log("unexpected:", tags.lookup[tag]);
            return;
          }
          read(read2());
          var name = readValue(74);
          var values = readCollectionItemValue();
          collection[name] = values;
        }
        read(read2());
        read(read2());
        return collection;
      }
      function readCollectionItemValue(name) {
        var tag = read1();
        if (tag === 127) {
          tag = read4();
        }
        read(read2());
        return readValues(tag, name);
      }
      obj.version = read1() + "." + read1();
      var bytes2and3 = read2();
      if (bytes2and3 >= 2 || bytes2and3 <= 61)
        obj.operation = operations.lookup[bytes2and3];
      if (bytes2and3 <= 7 || bytes2and3 >= 1024)
        obj.statusCode = statusCodes.lookup[bytes2and3];
      obj.id = read4();
      readGroups();
      if (position < buf.length)
        obj.data = buf.toString(encoding, position);
      return obj;
    };
    module.exports.handleUnknownTag = function log(tag, name, length, read) {
      var value = length ? read(length) : void 0;
      console.log("The spec is not clear on how to handle tag " + tag + ": " + name + "=" + String(value) + ". Please open a github issue to help find a solution!");
      return value;
    };
  }
});

// node_modules/ipp/lib/versions.js
var require_versions = __commonJS({
  "node_modules/ipp/lib/versions.js"(exports, module) {
    var versions = [];
    versions[256] = "1.0";
    versions[257] = "1.1";
    versions[512] = "2.0";
    versions[513] = "2.1";
    module.exports = require_ipputil().xref(versions);
  }
});

// node_modules/ipp/lib/attributes.js
var require_attributes = __commonJS({
  "node_modules/ipp/lib/attributes.js"(exports, module) {
    var tags = require_tags();
    function text(max) {
      if (!max) max = 1023;
      return { type: "text", max };
    }
    function integer(min, max) {
      if (max == MAX || max === void 0) max = 2147483647;
      if (min === void 0) min = -2147483648;
      return { type: "integer", tag: tags["integer"], min, max };
    }
    function rangeOfInteger(min, max) {
      if (max == MAX || max === void 0) max = 2147483647;
      if (min === void 0) min = -2147483648;
      return { type: "rangeOfInteger", tag: tags["rangeOfInteger"], min, max };
    }
    function boolean() {
      return { type: "boolean", tag: tags["boolean"] };
    }
    function charset() {
      return { type: "charset", tag: tags["charset"], max: 63 };
    }
    function keyword() {
      return { type: "keyword", tag: tags["keyword"], min: 1, max: 1023 };
    }
    function naturalLanguage() {
      return { type: "naturalLanguage", tag: tags["naturalLanguage"], max: 63 };
    }
    function dateTime() {
      return { type: "dateTime", tag: tags["dateTime"] };
    }
    function mimeMediaType() {
      return { type: "mimeMediaType", tag: tags["mimeMediaType"], max: 255 };
    }
    function uri(max) {
      return { type: "uri", tag: tags["uri"], max: max || 1023 };
    }
    function uriScheme() {
      return { type: "uriScheme", tag: tags["uriScheme"], max: 63 };
    }
    function enumeration() {
      return { type: "enumeration", tag: tags["enum"] };
    }
    function resolution() {
      return { type: "resolution", tag: tags["resolution"] };
    }
    function unknown() {
      return { type: "unknown", tag: tags["unknown"] };
    }
    function name(max) {
      return { type: "name", max: max || 1023 };
    }
    function novalue() {
      return { type: "novalue", tag: tags["no-value"] };
    }
    function octetString(max) {
      return { type: "octetString", tag: tags["octetString"], max: max || 1023 };
    }
    function _(arg1, arg2, arg3) {
      var args = Array.prototype.slice.call(arguments);
      args.lookup = {};
      const deferred = createDeferred(function() {
        args.forEach(function(a, i) {
          if (typeof a === "function")
            args[i] = a();
          args.lookup[args[i].type] = args[i];
        });
        args.alts = Object.keys(args.lookup).sort().join();
        return args;
      });
      return args.some(function(a) {
        return isDeferred(a);
      }) ? deferred : deferred();
    }
    var createDeferred = function(deferred) {
      deferred.isDeferred = true;
      return deferred;
    };
    var isDeferred = function(type) {
      return typeof type === "function" && type.isDeferred;
    };
    function setof(type) {
      if (isDeferred(type)) {
        return createDeferred(function() {
          type = type();
          type.setof = true;
          return type;
        });
      }
      if (typeof type === "function" && !isDeferred(type)) {
        type = type();
      }
      type.setof = true;
      return type;
    }
    function collection(group, name2) {
      if (!arguments.length)
        return { type: "collection", tag: tags.begCollection };
      if (typeof group === "string") {
        return createDeferred(function() {
          return {
            type: "collection",
            tag: tags.begCollection,
            members: attributes[group][name2].members
          };
        });
      }
      var defer = Object.keys(group).some(function(key) {
        return isDeferred(group[key]);
      });
      const deferred = createDeferred(function() {
        return {
          type: "collection",
          tag: tags.begCollection,
          members: resolve(group)
        };
      });
      return defer ? deferred : deferred();
    }
    var MAX = {};
    var attributes = {};
    attributes["Document Description"] = {
      "attributes-charset": charset,
      "attributes-natural-language": naturalLanguage,
      "compression": keyword,
      "copies-actual": setof(integer(1, MAX)),
      "cover-back-actual": setof(collection("Job Template", "cover-back")),
      "cover-front-actual": setof(collection("Job Template", "cover-front")),
      "current-page-order": keyword,
      "date-time-at-completed": _(dateTime, novalue),
      "date-time-at-creation": dateTime,
      "date-time-at-processing": _(dateTime, novalue),
      "detailed-status-messages": setof(text),
      "document-access-errors": setof(text),
      "document-charset": charset,
      "document-digital-signature": keyword,
      "document-format": mimeMediaType,
      "document-format-details": setof(collection("Operation", "document-format-details")),
      "document-format-details-detected": setof(collection("Operation", "document-format-details")),
      "document-format-detected": mimeMediaType,
      "document-format-version": text(127),
      "document-format-version-detected": text(127),
      "document-job-id": integer(1, MAX),
      "document-job-uri": uri,
      "document-message": text,
      "document-metadata": setof(octetString),
      "document-name": name,
      "document-natural-language": naturalLanguage,
      "document-number": integer(1, MAX),
      "document-printer-uri": uri,
      "document-state": enumeration,
      "document-state-message": text,
      "document-state-reasons": setof(keyword),
      "document-uri": uri,
      "document-uuid": uri(45),
      "errors-count": integer(0, MAX),
      "finishings-actual": setof(enumeration),
      "finishings-col-actual": setof(collection("Job Template", "finishings-col")),
      "force-front-side-actual": setof(integer(1, MAX)),
      "imposition-template-actual": setof(_(keyword, name)),
      "impressions": integer(0, MAX),
      "impressions-completed": integer(0, MAX),
      "impressions-completed-current-copy": integer(0, MAX),
      "insert-sheet-actual": setof(collection("Job Template", "insert-sheet")),
      "k-octets": integer(0, MAX),
      "k-octets-processed": integer(0, MAX),
      "last-document": boolean,
      "media-actual": setof(_(keyword, name)),
      "media-col-actual": setof(collection("Job Template", "media-col")),
      "media-input-tray-check-actual": setof(_(keyword, name)),
      "media-sheets": integer(0, MAX),
      "media-sheets-completed": integer(0, MAX),
      "more-info": uri,
      "number-up-actual": setof(integer),
      "orientation-requested-actual": setof(enumeration),
      "output-bin-actual": setof(name),
      "output-device-assigned": name(127),
      "overrides-actual": setof(collection("Document Template", "overrides")),
      "page-delivery-actual": setof(keyword),
      "page-order-received-actual": setof(keyword),
      "page-ranges-actual": setof(rangeOfInteger(1, MAX)),
      "pages": integer(0, MAX),
      "pages-completed": integer(0, MAX),
      "pages-completed-current-copy": integer(0, MAX),
      "presentation-direction-number-up-actual": setof(keyword),
      "print-content-optimize-actual": setof(keyword),
      "print-quality-actual": setof(enumeration),
      "printer-resolution-actual": setof(resolution),
      "printer-up-time": integer(1, MAX),
      "separator-sheets-actual": setof(collection("Job Template", "separator-sheets")),
      "sheet-completed-copy-number": integer(0, MAX),
      "sides-actual": setof(keyword),
      "time-at-completed": _(integer, novalue),
      "time-at-creation": integer,
      "time-at-processing": _(integer, novalue),
      "x-image-position-actual": setof(keyword),
      "x-image-shift-actual": setof(integer),
      "x-side1-image-shift-actual": setof(integer),
      "x-side2-image-shift-actual": setof(integer),
      "y-image-position-actual": setof(keyword),
      "y-image-shift-actual": setof(integer),
      "y-side1-image-shift-actual": setof(integer),
      "y-side2-image-shift-actual": setof(integer)
    };
    attributes["Document Template"] = {
      "copies": integer(1, MAX),
      "cover-back": collection("Job Template", "cover-back"),
      "cover-front": collection("Job Template", "cover-front"),
      "feed-orientation": keyword,
      "finishings": setof(enumeration),
      "finishings-col": collection("Job Template", "finishings-col"),
      "font-name-requested": name,
      "font-size-requested": integer(1, MAX),
      "force-front-side": setof(integer(1, MAX)),
      "imposition-template": _(keyword, name),
      "insert-sheet": setof(collection("Job Template", "insert-sheet")),
      "media": _(keyword, name),
      "media-col": collection("Job Template", "media-col"),
      "media-input-tray-check": _(keyword, name),
      "number-up": integer(1, MAX),
      "orientation-requested": enumeration,
      "overrides": setof(collection({
        //Any Document Template attribute (TODO)
        "document-copies": setof(rangeOfInteger),
        "document-numbers": setof(rangeOfInteger),
        "pages": setof(rangeOfInteger)
      })),
      "page-delivery": keyword,
      "page-order-received": keyword,
      "page-ranges": setof(rangeOfInteger(1, MAX)),
      "pdl-init-file": setof(collection("Job Template", "pdl-init-file")),
      "presentation-direction-number-up": keyword,
      "print-color-mode": keyword,
      "print-content-optimize": keyword,
      "print-quality": enumeration,
      "print-rendering-intent": keyword,
      "printer-resolution": resolution,
      "separator-sheets": collection("Job Template", "separator-sheets"),
      "sheet-collate": keyword,
      "sides": keyword,
      "x-image-position": keyword,
      "x-image-shift": integer,
      "x-side1-image-shift": integer,
      "x-side2-image-shift": integer,
      "y-image-position": keyword,
      "y-image-shift": integer,
      "y-side1-image-shift": integer,
      "y-side2-image-shift": integer
    };
    attributes["Event Notifications"] = {
      "notify-subscribed-event": keyword,
      "notify-text": text
    };
    attributes["Job Description"] = {
      "attributes-charset": charset,
      "attributes-natural-language": naturalLanguage,
      "compression-supplied": keyword,
      "copies-actual": setof(integer(1, MAX)),
      "cover-back-actual": setof(collection("Job Template", "cover-back")),
      "cover-front-actual": setof(collection("Job Template", "cover-front")),
      "current-page-order": keyword,
      "date-time-at-completed": _(dateTime, novalue),
      "date-time-at-creation": dateTime,
      "date-time-at-processing": _(dateTime, novalue),
      "document-charset-supplied": charset,
      "document-digital-signature-supplied": keyword,
      "document-format-details-supplied": setof(collection("Operation", "document-format-details")),
      "document-format-supplied": mimeMediaType,
      "document-format-version-supplied": text(127),
      "document-message-supplied": text,
      "document-metadata": setof(octetString),
      "document-name-supplied": name,
      "document-natural-language-supplied": naturalLanguage,
      "document-overrides-actual": setof(collection),
      "errors-count": integer(0, MAX),
      "finishings-actual": setof(enumeration),
      "finishings-col-actual": setof(collection("Job Template", "finishings-col")),
      "force-front-side-actual": setof(setof(integer(1, MAX))),
      "imposition-template-actual": setof(_(keyword, name)),
      "impressions-completed-current-copy": integer(0, MAX),
      "insert-sheet-actual": setof(collection("Job Template", "insert-sheet")),
      "job-account-id-actual": setof(name),
      "job-accounting-sheets-actual": setof(collection("Job Template", "job-accounting-sheets")),
      "job-accounting-user-id-actual": setof(name),
      "job-attribute-fidelity": boolean,
      "job-collation-type": enumeration,
      "job-collation-type-actual": setof(keyword),
      "job-copies-actual": setof(integer(1, MAX)),
      "job-cover-back-actual": setof(collection("Job Template", "cover-back")),
      "job-cover-front-actual": setof(collection("Job Template", "cover-front")),
      "job-detailed-status-messages": setof(text),
      "job-document-access-errors": setof(text),
      "job-error-sheet-actual": setof(collection("Job Template", "job-error-sheet")),
      "job-finishings-actual": setof(enumeration),
      "job-finishings-col-actual": setof(collection("Job Template", "media-col")),
      "job-hold-until-actual": setof(_(keyword, name)),
      "job-id": integer(1, MAX),
      "job-impressions": integer(0, MAX),
      "job-impressions-completed": integer(0, MAX),
      "job-k-octets": integer(0, MAX),
      "job-k-octets-processed": integer(0, MAX),
      "job-mandatory-attributes": setof(keyword),
      "job-media-sheets": integer(0, MAX),
      "job-media-sheets-completed": integer(0, MAX),
      "job-message-from-operator": text(127),
      "job-message-to-operator-actual": setof(text),
      "job-more-info": uri,
      "job-name": name,
      "job-originating-user-name": name,
      "job-originating-user-uri": uri,
      "job-pages": integer(0, MAX),
      "job-pages-completed": integer(0, MAX),
      "job-pages-completed-current-copy": integer(0, MAX),
      "job-printer-up-time": integer(1, MAX),
      "job-printer-uri": uri,
      "job-priority-actual": setof(integer(1, 100)),
      "job-save-printer-make-and-model": text(127),
      "job-sheet-message-actual": setof(text),
      "job-sheets-actual": setof(_(keyword, name)),
      "job-sheets-col-actual": setof(collection("Job Template", "job-sheets-col")),
      "job-state": _(enumeration, unknown),
      "job-state-message": text,
      "job-state-reasons": setof(keyword),
      "job-uri": uri,
      "job-uuid": uri(45),
      "media-actual": setof(_(keyword, name)),
      "media-col-actual": setof(collection("Job Template", "media-col")),
      "media-input-tray-check-actual": setof(_(keyword, name)),
      "multiple-document-handling-actual": setof(keyword),
      "number-of-documents": integer(0, MAX),
      "number-of-intervening-jobs": integer(0, MAX),
      "number-up-actual": setof(integer(1, MAX)),
      "orientation-requested-actual": setof(enumeration),
      "original-requesting-user-name": name,
      "output-bin-actual": setof(_(keyword, name)),
      "output-device-actual": setof(name(127)),
      "output-device-assigned": name(127),
      "overrides-actual": setof(collection("Job Template", "overrides")),
      "page-delivery-actual": setof(keyword),
      "page-order-received-actual": setof(keyword),
      "page-ranges-actual": setof(rangeOfInteger(1, MAX)),
      "presentation-direction-number-up-actual": setof(keyword),
      "print-content-optimize-actual": setof(keyword),
      "print-quality-actual": setof(enumeration),
      "printer-resolution-actual": setof(resolution),
      "separator-sheets-actual": setof(collection("Job Template", "separator-sheets")),
      "sheet-collate-actual": setof(keyword),
      "sheet-completed-copy-number": integer(0, MAX),
      "sheet-completed-document-number": integer(0, MAX),
      "sides-actual": setof(keyword),
      "time-at-completed": _(integer, novalue),
      "time-at-creation": integer,
      "time-at-processing": _(integer, novalue),
      "warnings-count": integer(0, MAX),
      "x-image-position-actual": setof(keyword),
      "x-image-shift-actual": setof(integer),
      "x-side1-image-shift-actual": setof(integer),
      "x-side2-image-shift-actual": setof(integer),
      "y-image-position-actual": setof(keyword),
      "y-image-shift-actual": setof(integer),
      "y-side1-image-shift-actual": setof(integer),
      "y-side2-image-shift-actual": setof(integer)
    };
    attributes["Job Template"] = {
      "copies": integer(1, MAX),
      "cover-back": collection({
        "cover-type": keyword,
        "media": _(keyword, name),
        "media-col": collection("Job Template", "media-col")
      }),
      "cover-front": collection({
        "cover-type": keyword,
        "media": _(keyword, name),
        "media-col": collection("Job Template", "media-col")
      }),
      "feed-orientation": keyword,
      "finishings": setof(enumeration),
      "finishings-col": collection({
        "finishing-template": name,
        "stitching": collection({
          "stitching-locations": setof(integer(0, MAX)),
          "stitching-offset": integer(0, MAX),
          "stitching-reference-edge": keyword
        })
      }),
      "font-name-requested": name,
      "font-size-requested": integer(1, MAX),
      "force-front-side": setof(integer(1, MAX)),
      "imposition-template": _(keyword, name),
      "insert-sheet": setof(collection({
        "insert-after-page-number": integer(0, MAX),
        "insert-count": integer(0, MAX),
        "media": _(keyword, name),
        "media-col": collection("Job Template", "media-col")
      })),
      "job-account-id": name,
      "job-accounting-sheets": collection({
        "job-accounting-output-bin": _(keyword, name),
        "job-accounting-sheets-type": _(keyword, name),
        "media": _(keyword, name),
        "media-col": collection("Job Template", "media-col")
      }),
      "job-accounting-user-id": name,
      "job-copies": integer(1, MAX),
      "job-cover-back": collection("Job Template", "cover-back"),
      "job-cover-front": collection("Job Template", "cover-front"),
      "job-delay-output-until": _(keyword, name),
      "job-delay-output-until-time": dateTime,
      "job-error-action": keyword,
      "job-error-sheet": collection({
        "job-error-sheet-type": _(keyword, name),
        "job-error-sheet-when": keyword,
        "media": _(keyword, name),
        "media-col": collection("Job Template", "media-col")
      }),
      "job-finishings": setof(enumeration),
      "job-finishings-col": collection("Job Template", "finishings-col"),
      "job-hold-until": _(keyword, name),
      "job-hold-until-time": dateTime,
      "job-message-to-operator": text,
      "job-phone-number": uri,
      "job-priority": integer(1, 100),
      "job-recipient-name": name,
      "job-save-disposition": collection({
        "save-disposition": keyword,
        "save-info": setof(collection({
          "save-document-format": mimeMediaType,
          "save-location": uri,
          "save-name": name
        }))
      }),
      "job-sheet-message": text,
      "job-sheets": _(keyword, name),
      "job-sheets-col": collection({
        "job-sheets": _(keyword, name),
        "media": _(keyword, name),
        "media-col": collection("Job Template", "media-col")
      }),
      "media": _(keyword, name),
      "media-col": collection({
        "media-back-coating": _(keyword, name),
        "media-bottom-margin": integer(0, MAX),
        "media-color": _(keyword, name),
        "media-front-coating": _(keyword, name),
        "media-grain": _(keyword, name),
        "media-hole-count": integer(0, MAX),
        "media-info": text(255),
        "media-key": _(keyword, name),
        "media-left-margin": integer(0, MAX),
        "media-order-count": integer(1, MAX),
        "media-pre-printed": _(keyword, name),
        "media-recycled": _(keyword, name),
        "media-right-margin": integer(0, MAX),
        "media-size": collection({
          "x-dimension": integer(0, MAX),
          "y-dimension": integer(0, MAX)
        }),
        "media-size-name": _(keyword, name),
        "media-source": _(keyword, name),
        "media-thickness": integer(1, MAX),
        "media-tooth": _(keyword, name),
        "media-top-margin": integer(0, MAX),
        "media-type": _(keyword, name),
        "media-weight-metric": integer(0, MAX)
      }),
      "media-input-tray-check": _(keyword, name),
      "multiple-document-handling": keyword,
      "number-up": integer(1, MAX),
      "orientation-requested": enumeration,
      "output-bin": _(keyword, name),
      "output-device": name(127),
      "overrides": setof(collection({
        //Any Job Template attribute (TODO)
        "document-copies": setof(rangeOfInteger),
        "document-numbers": setof(rangeOfInteger),
        "pages": setof(rangeOfInteger)
      })),
      "page-delivery": keyword,
      "page-order-received": keyword,
      "page-ranges": setof(rangeOfInteger(1, MAX)),
      "pages-per-subset": setof(integer(1, MAX)),
      "pdl-init-file": collection({
        "pdl-init-file-entry": name,
        "pdl-init-file-location": uri,
        "pdl-init-file-name": name
      }),
      "presentation-direction-number-up": keyword,
      "print-color-mode": keyword,
      "print-content-optimize": keyword,
      "print-quality": enumeration,
      "print-rendering-intent": keyword,
      "printer-resolution": resolution,
      "proof-print": collection({
        "media": _(keyword, name),
        "media-col": collection("Job Template", "media-col"),
        "proof-print-copies": integer(0, MAX)
      }),
      "separator-sheets": collection({
        "media": _(keyword, name),
        "media-col": collection("Job Template", "media-col"),
        "separator-sheets-type": setof(keyword)
      }),
      "sheet-collate": keyword,
      "sides": keyword,
      "x-image-position": keyword,
      "x-image-shift": integer,
      "x-side1-image-shift": integer,
      "x-side2-image-shift": integer,
      "y-image-position": keyword,
      "y-image-shift": integer,
      "y-side1-image-shift": integer,
      "y-side2-image-shift": integer
    };
    attributes["Operation"] = {
      "attributes-charset": charset,
      "attributes-natural-language": naturalLanguage,
      "compression": keyword,
      "detailed-status-message": text,
      "document-access-error": text,
      "document-charset": charset,
      "document-digital-signature": keyword,
      "document-format": mimeMediaType,
      "document-format-details": setof(collection({
        "document-format": mimeMediaType,
        "document-format-device-id": text(127),
        "document-format-version": text(127),
        "document-natural-language": setof(naturalLanguage),
        "document-source-application-name": name,
        "document-source-application-version": text(127),
        "document-source-os-name": name(40),
        "document-source-os-version": text(40)
      })),
      "document-message": text,
      "document-metadata": setof(octetString),
      "document-name": name,
      "document-natural-language": naturalLanguage,
      "document-password": octetString,
      "document-uri": uri,
      "first-index": integer(1, MAX),
      "identify-actions": setof(keyword),
      "ipp-attribute-fidelity": boolean,
      "job-hold-until": _(keyword, name),
      "job-id": integer(1, MAX),
      "job-ids": setof(integer(1, MAX)),
      "job-impressions": integer(0, MAX),
      "job-k-octets": integer(0, MAX),
      "job-mandatory-attributes": setof(keyword),
      "job-media-sheets": integer(0, MAX),
      "job-message-from-operator": text(127),
      "job-name": name,
      "job-password": octetString(255),
      "job-password-encryption": _(keyword, name),
      "job-state": enumeration,
      "job-state-message": text,
      "job-state-reasons": setof(keyword),
      "job-uri": uri,
      "last-document": boolean,
      "limit": integer(1, MAX),
      "message": text(127),
      "my-jobs": boolean,
      "original-requesting-user-name": name,
      "preferred-attributes": collection,
      "printer-message-from-operator": text(127),
      "printer-uri": uri,
      "requested-attributes": setof(keyword),
      "requesting-user-name": name,
      "requesting-user-uri": uri,
      "status-message": text(255),
      "which-jobs": keyword
    };
    attributes["Printer Description"] = {
      "charset-configured": charset,
      "charset-supported": setof(charset),
      "color-supported": boolean,
      "compression-supported": setof(keyword),
      "copies-default": integer(1, MAX),
      "copies-supported": rangeOfInteger(1, MAX),
      "cover-back-default": collection("Job Template", "cover-back"),
      "cover-back-supported": setof(keyword),
      "cover-front-default": collection("Job Template", "cover-front"),
      "cover-front-supported": setof(keyword),
      "device-service-count": integer(1, MAX),
      "device-uuid": uri(45),
      "document-charset-default": charset,
      "document-charset-supported": setof(charset),
      "document-creation-attributes-supported": setof(keyword),
      "document-digital-signature-default": keyword,
      "document-digital-signature-supported": setof(keyword),
      "document-format-default": mimeMediaType,
      "document-format-details-default": collection("Operation", "document-format-details"),
      "document-format-details-supported": setof(keyword),
      "document-format-supported": setof(mimeMediaType),
      "document-format-varying-attributes": setof(keyword),
      "document-format-version-default": text(127),
      "document-format-version-supported": setof(text(127)),
      "document-natural-language-default": naturalLanguage,
      "document-natural-language-supported": setof(naturalLanguage),
      "document-password-supported": integer(0, 1023),
      "feed-orientation-default": keyword,
      "feed-orientation-supported": keyword,
      "finishings-col-default": collection("Job Template", "finishings-col"),
      "finishings-col-ready": setof(collection("Job Template", "finishings-col")),
      "finishings-col-supported": setof(keyword),
      "finishings-default": setof(enumeration),
      "finishings-ready": setof(enumeration),
      "finishings-supported": setof(enumeration),
      "font-name-requested-default": name,
      "font-name-requested-supported": setof(name),
      "font-size-requested-default": integer(1, MAX),
      "font-size-requested-supported": setof(rangeOfInteger(1, MAX)),
      "force-front-side-default (under review)": setof(integer(1, MAX)),
      "force-front-side-supported (under review)": rangeOfInteger(1, MAX),
      "generated-natural-language-supported": setof(naturalLanguage),
      "identify-actions-default": setof(keyword),
      "identify-actions-supported": setof(keyword),
      "imposition-template-default": _(keyword, name),
      "imposition-template-supported": setof(_(keyword, name)),
      "insert-after-page-number-supported": rangeOfInteger(0, MAX),
      "insert-count-supported": rangeOfInteger(0, MAX),
      "insert-sheet-default": setof(collection("Job Template", "insert-sheet")),
      "insert-sheet-supported": setof(keyword),
      "ipp-features-supported": setof(keyword),
      "ipp-versions-supported": setof(keyword),
      "ippget-event-life": integer(15, MAX),
      "job-account-id-default": _(name, novalue),
      "job-account-id-supported": boolean,
      "job-accounting-sheets-default": _(collection("Job Template", "job-accounting-sheets"), novalue),
      "job-accounting-sheets-supported": setof(keyword),
      "job-accounting-user-id-default": _(name, novalue),
      "job-accounting-user-id-supported": boolean,
      "job-constraints-supported": setof(collection),
      "job-copies-default": integer(1, MAX),
      "job-copies-supported": rangeOfInteger(1, MAX),
      "job-cover-back-default": collection("Job Template", "cover-back"),
      "job-cover-back-supported": setof(keyword),
      "job-cover-front-default": collection("Job Template", "cover-front"),
      "job-cover-front-supported": setof(keyword),
      "job-creation-attributes-supported": setof(keyword),
      "job-delay-output-until-default": _(keyword, name),
      "job-delay-output-until-supported": setof(_(keyword, name)),
      "job-delay-output-until-time-supported": rangeOfInteger(0, MAX),
      "job-error-action-default": keyword,
      "job-error-action-supported": setof(keyword),
      "job-error-sheet-default": _(collection("Job Template", "job-error-sheet"), novalue),
      "job-error-sheet-supported": setof(keyword),
      "job-finishings-col-default": collection("Job Template", "finishings-col"),
      "job-finishings-col-ready": setof(collection("Job Template", "finishings-col")),
      "job-finishings-col-supported": setof(keyword),
      "job-finishings-default": setof(enumeration),
      "job-finishings-ready": setof(enumeration),
      "job-finishings-supported": setof(enumeration),
      "job-hold-until-default": _(keyword, name),
      "job-hold-until-supported": setof(_(keyword, name)),
      "job-hold-until-time-supported": rangeOfInteger(0, MAX),
      "job-ids-supported": boolean,
      "job-impressions-supported": rangeOfInteger(0, MAX),
      "job-k-octets-supported": rangeOfInteger(0, MAX),
      "job-media-sheets-supported": rangeOfInteger(0, MAX),
      "job-message-to-operator-default": text,
      "job-message-to-operator-supported": boolean,
      "job-password-encryption-supported": setof(_(keyword, name)),
      "job-password-supported": integer(0, 255),
      "job-phone-number-default": _(uri, novalue),
      "job-phone-number-supported": boolean,
      "job-priority-default": integer(1, 100),
      "job-priority-supported": integer(1, 100),
      "job-recipient-name-default": _(name, novalue),
      "job-recipient-name-supported": boolean,
      "job-resolvers-supported": setof(collection({
        "resolver-name": name
      })),
      "job-settable-attributes-supported": setof(keyword),
      "job-sheet-message-default": text,
      "job-sheet-message-supported": boolean,
      "job-sheets-col-default": collection("Job Template", "job-sheets-col"),
      "job-sheets-col-supported": setof(keyword),
      "job-sheets-default": _(keyword, name),
      "job-sheets-supported": setof(_(keyword, name)),
      "job-spooling-supported": keyword,
      "max-save-info-supported": integer(1, MAX),
      "max-stitching-locations-supported": integer(1, MAX),
      "media-back-coating-supported": setof(_(keyword, name)),
      "media-bottom-margin-supported": setof(integer(0, MAX)),
      "media-col-database": setof(collection({
        //TODO: Member attributes are the same as the
        // "media-col" Job Template attribute
        "media-source-properties": collection({
          "media-source-feed-direction": keyword,
          "media-source-feed-orientation": enumeration
        })
      })),
      "media-col-default": collection("Job Template", "media-col"),
      "media-col-ready": setof(collection({
        //TODO: Member attributes are the same as the
        // "media-col" Job Template attribute
        "media-source-properties": collection({
          "media-source-feed-direction": keyword,
          "media-source-feed-orientation": enumeration
        })
      })),
      "media-col-supported": setof(keyword),
      "media-color-supported": setof(_(keyword, name)),
      "media-default": _(keyword, name, novalue),
      "media-front-coating-supported": setof(_(keyword, name)),
      "media-grain-supported": setof(_(keyword, name)),
      "media-hole-count-supported": setof(rangeOfInteger(0, MAX)),
      "media-info-supported": boolean,
      "media-input-tray-check-default": _(keyword, name, novalue),
      "media-input-tray-check-supported": setof(_(keyword, name)),
      "media-key-supported": setof(_(keyword, name)),
      "media-left-margin-supported": setof(integer(0, MAX)),
      "media-order-count-supported": setof(rangeOfInteger(1, MAX)),
      "media-pre-printed-supported": setof(_(keyword, name)),
      "media-ready": setof(_(keyword, name)),
      "media-recycled-supported": setof(_(keyword, name)),
      "media-right-margin-supported": setof(integer(0, MAX)),
      "media-size-supported": setof(collection({
        "x-dimension": _(integer(1, MAX), rangeOfInteger(1, MAX)),
        "y-dimension": _(integer(1, MAX), rangeOfInteger(1, MAX))
      })),
      "media-source-supported": setof(_(keyword, name)),
      "media-supported": setof(_(keyword, name)),
      "media-thickness-supported": rangeOfInteger(1, MAX),
      "media-tooth-supported": setof(_(keyword, name)),
      "media-top-margin-supported": setof(integer(0, MAX)),
      "media-type-supported": setof(_(keyword, name)),
      "media-weight-metric-supported": setof(rangeOfInteger(0, MAX)),
      "multiple-document-handling-default": keyword,
      "multiple-document-handling-supported": setof(keyword),
      "multiple-document-jobs-supported": boolean,
      "multiple-operation-time-out": integer(1, MAX),
      "multiple-operation-timeout-action": keyword,
      "natural-language-configured": naturalLanguage,
      "number-up-default": integer(1, MAX),
      "number-up-supported": _(integer(1, MAX), rangeOfInteger(1, MAX)),
      "operations-supported": setof(enumeration),
      "orientation-requested-default": _(novalue, enumeration),
      "orientation-requested-supported": setof(enumeration),
      "output-bin-default": _(keyword, name),
      "output-bin-supported": setof(_(keyword, name)),
      "output-device-supported": setof(name(127)),
      "overrides-supported": setof(keyword),
      "page-delivery-default": keyword,
      "page-delivery-supported": setof(keyword),
      "page-order-received-default": keyword,
      "page-order-received-supported": setof(keyword),
      "page-ranges-supported": boolean,
      "pages-per-minute": integer(0, MAX),
      "pages-per-minute-color": integer(0, MAX),
      "pages-per-subset-supported": boolean,
      "parent-printers-supported": setof(uri),
      "pdl-init-file-default": _(collection("Job Template", "pdl-init-file"), novalue),
      "pdl-init-file-entry-supported": setof(name),
      "pdl-init-file-location-supported": setof(uri),
      "pdl-init-file-name-subdirectory-supported": boolean,
      "pdl-init-file-name-supported": setof(name),
      "pdl-init-file-supported": setof(keyword),
      "pdl-override-supported": keyword,
      "preferred-attributes-supported": boolean,
      "presentation-direction-number-up-default": keyword,
      "presentation-direction-number-up-supported": setof(keyword),
      "print-color-mode-default": keyword,
      "print-color-mode-supported": setof(keyword),
      "print-content-optimize-default": keyword,
      "print-content-optimize-supported": setof(keyword),
      "print-quality-default": enumeration,
      "print-quality-supported": setof(enumeration),
      "print-rendering-intent-default": keyword,
      "print-rendering-intent-supported": setof(keyword),
      "printer-alert": setof(octetString),
      "printer-alert-description": setof(text),
      "printer-charge-info": text,
      "printer-charge-info-uri": uri,
      "printer-current-time": dateTime,
      "printer-detailed-status-messages": setof(text),
      "printer-device-id": text(1023),
      "printer-driver-installer": uri,
      "printer-geo-location": uri,
      "printer-get-attributes-supported": setof(keyword),
      "printer-icc-profiles": setof(collection({
        "xri-authentication": name,
        "profile-url": uri
      })),
      "printer-icons": setof(uri),
      "printer-info": text(127),
      "printer-is-accepting-jobs": boolean,
      "printer-location": text(127),
      "printer-make-and-model": text(127),
      "printer-mandatory-job-attributes": setof(keyword),
      "printer-message-date-time": dateTime,
      "printer-message-from-operator": text(127),
      "printer-message-time": integer,
      "printer-more-info": uri,
      "printer-more-info-manufacturer": uri,
      "printer-name": name(127),
      "printer-organization": setof(text),
      "printer-organizational-unit": setof(text),
      "printer-resolution-default": resolution,
      "printer-resolution-supported": resolution,
      "printer-settable-attributes-supported": setof(keyword),
      "printer-state": enumeration,
      "printer-state-change-date-time": dateTime,
      "printer-state-change-time": integer(1, MAX),
      "printer-state-message": text,
      "printer-state-reasons": setof(keyword),
      "printer-supply": setof(octetString),
      "printer-supply-description": setof(text),
      "printer-supply-info-uri": uri,
      "printer-up-time": integer(1, MAX),
      "printer-uri-supported": setof(uri),
      "printer-uuid": uri(45),
      "printer-xri-supported": setof(collection({
        "xri-authentication": keyword,
        "xri-security": keyword,
        "xri-uri": uri
      })),
      "proof-print-default": _(collection("Job Template", "proof-print"), novalue),
      "proof-print-supported": setof(keyword),
      "pwg-raster-document-resolution-supported": setof(resolution),
      "pwg-raster-document-sheet-back": keyword,
      "pwg-raster-document-type-supported": setof(keyword),
      "queued-job-count": integer(0, MAX),
      "reference-uri-schemes-supported": setof(uriScheme),
      "repertoire-supported": setof(_(keyword, name)),
      "requesting-user-uri-supported": boolean,
      "save-disposition-supported": setof(keyword),
      "save-document-format-default": mimeMediaType,
      "save-document-format-supported": setof(mimeMediaType),
      "save-location-default": uri,
      "save-location-supported": setof(uri),
      "save-name-subdirectory-supported": boolean,
      "save-name-supported": boolean,
      "separator-sheets-default": collection("Job Template", "separator-sheets"),
      "separator-sheets-supported": setof(keyword),
      "sheet-collate-default": keyword,
      "sheet-collate-supported": setof(keyword),
      "sides-default": keyword,
      "sides-supported": setof(keyword),
      "stitching-locations-supported": setof(_(integer(0, MAX), rangeOfInteger(0, MAX))),
      "stitching-offset-supported": setof(_(integer(0, MAX), rangeOfInteger(0, MAX))),
      "subordinate-printers-supported": setof(uri),
      "uri-authentication-supported": setof(keyword),
      "uri-security-supported": setof(keyword),
      "user-defined-values-supported": setof(keyword),
      "which-jobs-supported": setof(keyword),
      "x-image-position-default": keyword,
      "x-image-position-supported": setof(keyword),
      "x-image-shift-default": integer,
      "x-image-shift-supported": rangeOfInteger,
      "x-side1-image-shift-default": integer,
      "x-side1-image-shift-supported": rangeOfInteger,
      "x-side2-image-shift-default": integer,
      "x-side2-image-shift-supported": rangeOfInteger,
      "xri-authentication-supported": setof(keyword),
      "xri-security-supported": setof(keyword),
      "xri-uri-scheme-supported": setof(uriScheme),
      "y-image-position-default": keyword,
      "y-image-position-supported": setof(keyword),
      "y-image-shift-default": integer,
      "y-image-shift-supported": rangeOfInteger,
      "y-side1-image-shift-default": integer,
      "y-side1-image-shift-supported": rangeOfInteger,
      "y-side2-image-shift-default": integer,
      "y-side2-image-shift-supported": rangeOfInteger
    };
    attributes["Subscription Description"] = {
      "notify-job-id": integer(1, MAX),
      "notify-lease-expiration-time": integer(0, MAX),
      "notify-printer-up-time": integer(1, MAX),
      "notify-printer-uri": uri,
      "notify-sequence-number": integer(0, MAX),
      "notify-subscriber-user-name": name,
      "notify-subscriber-user-uri": uri,
      "notify-subscription-id": integer(1, MAX),
      "subscription-uuid": uri
    };
    attributes["Subscription Template"] = {
      "notify-attributes": setof(keyword),
      "notify-attributes-supported": setof(keyword),
      "notify-charset": charset,
      "notify-events": setof(keyword),
      "notify-events-default": setof(keyword),
      "notify-events-supported": setof(keyword),
      "notify-lease-duration": integer(0, 67108863),
      "notify-lease-duration-default": integer(0, 67108863),
      "notify-lease-duration-supported": setof(_(integer(0, 67108863), rangeOfInteger(0, 67108863))),
      "notify-max-events-supported": integer(2, MAX),
      "notify-natural-language": naturalLanguage,
      "notify-pull-method": keyword,
      "notify-pull-method-supported": setof(keyword),
      "notify-recipient-uri": uri,
      "notify-schemes-supported": setof(uriScheme),
      "notify-time-interval": integer(0, MAX),
      "notify-user-data": octetString(63)
    };
    function resolve(obj) {
      if (obj.type) return obj;
      Object.keys(obj).forEach(function(name2) {
        var item = obj[name2];
        if (typeof item === "function")
          obj[name2] = item();
        else if (typeof item === "object" && !item.type)
          obj[name2] = resolve(item);
      });
      return obj;
    }
    resolve(attributes);
    module.exports = attributes;
  }
});

// node_modules/ipp/lib/keywords.js
var require_keywords = __commonJS({
  "node_modules/ipp/lib/keywords.js"(exports, module) {
    var attributes = require_attributes();
    function keyword(arr) {
      arr = arr.slice(0);
      arr.type = "keyword";
      return arr;
    }
    function keyword_name(arr) {
      arr = arr.slice(0);
      arr.type = "keyword | name";
      return arr;
    }
    function keyword_name_novalue(arr) {
      arr = arr.slice(0);
      arr.type = "keyword | name | no-value";
      return arr;
    }
    function setof_keyword(arr) {
      arr = arr.slice(0);
      arr.type = "1setOf keyword";
      return arr;
    }
    function setof_keyword_name(arr) {
      arr = arr.slice(0);
      arr.type = "1setOf keyword | name";
      return arr;
    }
    var media = {
      "size name": [
        "a",
        "arch-a",
        "arch-b",
        "arch-c",
        "arch-d",
        "arch-e",
        "asme_f_28x40in",
        "b",
        "c",
        "choice_iso_a4_210x297mm_na_letter_8.5x11in",
        "d",
        "e",
        "executive",
        "f",
        "folio",
        "invoice",
        "iso-a0",
        "iso-a1",
        "iso-a2",
        "iso-a3",
        "iso-a4",
        "iso-a5",
        "iso-a6",
        "iso-a7",
        "iso-a8",
        "iso-a9",
        "iso-a10",
        "iso-b0",
        "iso-b1",
        "iso-b2",
        "iso-b3",
        "iso-b4",
        "iso-b5",
        "iso-b6",
        "iso-b7",
        "iso-b8",
        "iso-b9",
        "iso-b10",
        "iso-c3",
        "iso-c4",
        "iso-c5",
        "iso-c6",
        "iso-designated-long",
        "iso_2a0_1189x1682mm",
        "iso_a0_841x1189mm",
        "iso_a1_594x841mm",
        "iso_a1x3_841x1783mm",
        "iso_a1x4_841x2378mm",
        "iso_a2_420x594mm",
        "iso_a2x3_594x1261mm",
        "iso_a2x4_594x1682mm",
        "iso_a2x5_594x2102mm",
        "iso_a3-extra_322x445mm",
        "iso_a3_297x420mm",
        "iso_a0x3_1189x2523mm",
        "iso_a3x3_420x891mm",
        "iso_a3x4_420x1189mm",
        "iso_a3x5_420x1486mm",
        "iso_a3x6_420x1783mm",
        "iso_a3x7_420x2080mm",
        "iso_a4-extra_235.5x322.3mm",
        "iso_a4-tab_225x297mm",
        "iso_a4_210x297mm",
        "iso_a4x3_297x630mm",
        "iso_a4x4_297x841mm",
        "iso_a4x5_297x1051mm",
        "iso_a4x6_297x1261mm",
        "iso_a4x7_297x1471mm",
        "iso_a4x8_297x1682mm",
        "iso_a4x9_297x1892mm",
        "iso_a5-extra_174x235mm",
        "iso_a5_148x210mm",
        "iso_a6_105x148mm",
        "iso_a7_74x105mm",
        "iso_a8_52x74mm",
        "iso_a9_37x52mm",
        "iso_a10_26x37mm",
        "iso_b0_1000x1414mm",
        "iso_b1_707x1000mm",
        "iso_b2_500x707mm",
        "iso_b3_353x500mm",
        "iso_b4_250x353mm",
        "iso_b5-extra_201x276mm",
        "iso_b5_176x250mm",
        "iso_b6_125x176mm",
        "iso_b6c4_125x324mm",
        "iso_b7_88x125mm",
        "iso_b8_62x88mm",
        "iso_b9_44x62mm",
        "iso_b10_31x44mm",
        "iso_c0_917x1297mm",
        "iso_c1_648x917mm",
        "iso_c2_458x648mm",
        "iso_c3_324x458mm",
        "iso_c4_229x324mm",
        "iso_c5_162x229mm",
        "iso_c6_114x162mm",
        "iso_c6c5_114x229mm",
        "iso_c7_81x114mm",
        "iso_c7c6_81x162mm",
        "iso_c8_57x81mm",
        "iso_c9_40x57mm",
        "iso_c10_28x40mm",
        "iso_dl_110x220mm",
        "iso_ra0_860x1220mm",
        "iso_ra1_610x860mm",
        "iso_ra2_430x610mm",
        "iso_sra0_900x1280mm",
        "iso_sra1_640x900mm",
        "iso_sra2_450x640mm",
        "jis-b0",
        "jis-b1",
        "jis-b2",
        "jis-b3",
        "jis-b4",
        "jis-b5",
        "jis-b6",
        "jis-b7",
        "jis-b8",
        "jis-b9",
        "jis-b10",
        "jis_b0_1030x1456mm",
        "jis_b1_728x1030mm",
        "jis_b2_515x728mm",
        "jis_b3_364x515mm",
        "jis_b4_257x364mm",
        "jis_b5_182x257mm",
        "jis_b6_128x182mm",
        "jis_b7_91x128mm",
        "jis_b8_64x91mm",
        "jis_b9_45x64mm",
        "jis_b10_32x45mm",
        "jis_exec_216x330mm",
        "jpn_chou2_111.1x146mm",
        "jpn_chou3_120x235mm",
        "jpn_chou4_90x205mm",
        "jpn_hagaki_100x148mm",
        "jpn_kahu_240x322.1mm",
        "jpn_kaku2_240x332mm",
        "jpn_oufuku_148x200mm",
        "jpn_you4_105x235mm",
        "ledger",
        "monarch",
        "na-5x7",
        "na-6x9",
        "na-7x9",
        "na-8x10",
        "na-9x11",
        "na-9x12",
        "na-10x13",
        "na-10x14",
        "na-10x15",
        "na-legal",
        "na-letter",
        "na-number-9",
        "na-number-10",
        "na_5x7_5x7in",
        "na_6x9_6x9in",
        "na_7x9_7x9in",
        "na_9x11_9x11in",
        "na_10x11_10x11in",
        "na_10x13_10x13in",
        "na_10x14_10x14in",
        "na_10x15_10x15in",
        "na_11x12_11x12in",
        "na_11x15_11x15in",
        "na_12x19_12x19in",
        "na_a2_4.375x5.75in",
        "na_arch-a_9x12in",
        "na_arch-b_12x18in",
        "na_arch-c_18x24in",
        "na_arch-d_24x36in",
        "na_arch-e_36x48in",
        "na_b-plus_12x19.17in",
        "na_c5_6.5x9.5in",
        "na_c_17x22in",
        "na_d_22x34in",
        "na_e_34x44in",
        "na_edp_11x14in",
        "na_eur-edp_12x14in",
        "na_executive_7.25x10.5in",
        "na_f_44x68in",
        "na_fanfold-eur_8.5x12in",
        "na_fanfold-us_11x14.875in",
        "na_foolscap_8.5x13in",
        "na_govt-legal_8x13in",
        "na_govt-letter_8x10in",
        "na_index-3x5_3x5in",
        "na_index-4x6-ext_6x8in",
        "na_index-4x6_4x6in",
        "na_index-5x8_5x8in",
        "na_invoice_5.5x8.5in",
        "na_ledger_11x17in",
        "na_legal-extra_9.5x15in",
        "na_legal_8.5x14in",
        "na_letter-extra_9.5x12in",
        "na_letter-plus_8.5x12.69in",
        "na_letter_8.5x11in",
        "na_monarch_3.875x7.5in",
        "na_number-9_3.875x8.875in",
        "na_number-10_4.125x9.5in",
        "na_number-11_4.5x10.375in",
        "na_number-12_4.75x11in",
        "na_number-14_5x11.5in",
        "na_personal_3.625x6.5in",
        "na_quarto_8.5x10.83in",
        "na_super-a_8.94x14in",
        "na_super-b_13x19in",
        "na_wide-format_30x42in",
        "om_dai-pa-kai_275x395mm",
        "om_folio-sp_215x315mm",
        "om_folio_210x330mm",
        "om_invite_220x220mm",
        "om_italian_110x230mm",
        "om_juuro-ku-kai_198x275mm",
        "om_large-photo_200x300",
        "om_pa-kai_267x389mm",
        "om_postfix_114x229mm",
        "om_small-photo_100x150mm",
        "prc_1_102x165mm",
        "prc_2_102x176mm",
        "prc_3_125x176mm",
        "prc_4_110x208mm",
        "prc_5_110x220mm",
        "prc_6_120x320mm",
        "prc_7_160x230mm",
        "prc_8_120x309mm",
        "prc_10_324x458mm",
        "prc_16k_146x215mm",
        "prc_32k_97x151mm",
        "quarto",
        "roc_8k_10.75x15.5in",
        "roc_16k_7.75x10.75in",
        "super-b",
        "tabloid"
      ],
      "media name": [
        "a-translucent",
        "a-transparent",
        "a-white",
        "arch-a-translucent",
        "arch-a-transparent",
        "arch-a-white",
        "arch-axsynchro-translucent",
        "arch-axsynchro-transparent",
        "arch-axsynchro-white",
        "arch-b-translucent",
        "arch-b-transparent",
        "arch-b-white",
        "arch-bxsynchro-translucent",
        "arch-bxsynchro-transparent",
        "arch-bxsynchro-white",
        "arch-c-translucent",
        "arch-c-transparent",
        "arch-c-white",
        "arch-cxsynchro-translucent",
        "arch-cxsynchro-transparent",
        "arch-cxsynchro-white",
        "arch-d-translucent",
        "arch-d-transparent",
        "arch-d-white",
        "arch-dxsynchro-translucent",
        "arch-dxsynchro-transparent",
        "arch-dxsynchro-white",
        "arch-e-translucent",
        "arch-e-transparent",
        "arch-e-white",
        "arch-exsynchro-translucent",
        "arch-exsynchro-transparent",
        "arch-exsynchro-white",
        "auto-fixed-size-translucent",
        "auto-fixed-size-transparent",
        "auto-fixed-size-white",
        "auto-synchro-translucent",
        "auto-synchro-transparent",
        "auto-synchro-white",
        "auto-translucent",
        "auto-transparent",
        "auto-white",
        "axsynchro-translucent",
        "axsynchro-transparent",
        "axsynchro-white",
        "b-translucent",
        "b-transparent",
        "b-white",
        "bxsynchro-translucent",
        "bxsynchro-transparent",
        "bxsynchro-white",
        "c-translucent",
        "c-transparent",
        "c-white",
        "custom1",
        "custom2",
        "custom3",
        "custom4",
        "custom5",
        "custom6",
        "custom7",
        "custom8",
        "custom9",
        "custom10",
        "cxsynchro-translucent",
        "cxsynchro-transparent",
        "cxsynchro-white",
        "d-translucent",
        "d-transparent",
        "d-white",
        "default",
        "dxsynchro-translucent",
        "dxsynchro-transparent",
        "dxsynchro-white",
        "e-translucent",
        "e-transparent",
        "e-white",
        "executive-white",
        "exsynchro-translucent",
        "exsynchro-transparent",
        "exsynchro-white",
        "folio-white",
        "invoice-white",
        "iso-a0-translucent",
        "iso-a0-transparent",
        "iso-a0-white",
        "iso-a0xsynchro-translucent",
        "iso-a0xsynchro-transparent",
        "iso-a0xsynchro-white",
        "iso-a1-translucent",
        "iso-a1-transparent",
        "iso-a1-white",
        "iso-a1x3-translucent",
        "iso-a1x3-transparent",
        "iso-a1x3-white",
        "iso-a1x4- translucent",
        "iso-a1x4-transparent",
        "iso-a1x4-white",
        "iso-a1xsynchro-translucent",
        "iso-a1xsynchro-transparent",
        "iso-a1xsynchro-white",
        "iso-a2-translucent",
        "iso-a2-transparent",
        "iso-a2-white",
        "iso-a2x3-translucent",
        "iso-a2x3-transparent",
        "iso-a2x3-white",
        "iso-a2x4-translucent",
        "iso-a2x4-transparent",
        "iso-a2x4-white",
        "iso-a2x5-translucent",
        "iso-a2x5-transparent",
        "iso-a2x5-white",
        "iso-a2xsynchro-translucent",
        "iso-a2xsynchro-transparent",
        "iso-a2xsynchro-white",
        "iso-a3-colored",
        "iso-a3-translucent",
        "iso-a3-transparent",
        "iso-a3-white",
        "iso-a3x3-translucent",
        "iso-a3x3-transparent",
        "iso-a3x3-white",
        "iso-a3x4-translucent",
        "iso-a3x4-transparent",
        "iso-a3x4-white",
        "iso-a3x5-translucent",
        "iso-a3x5-transparent",
        "iso-a3x5-white",
        "iso-a3x6-translucent",
        "iso-a3x6-transparent",
        "iso-a3x6-white",
        "iso-a3x7-translucent",
        "iso-a3x7-transparent",
        "iso-a3x7-white",
        "iso-a3xsynchro-translucent",
        "iso-a3xsynchro-transparent",
        "iso-a3xsynchro-white",
        "iso-a4-colored",
        "iso-a4-translucent",
        "iso-a4-transparent",
        "iso-a4-white",
        "iso-a4x3-translucent",
        "iso-a4x3-transparent",
        "iso-a4x3-white",
        "iso-a4x4-translucent",
        "iso-a4x4-transparent",
        "iso-a4x4-white",
        "iso-a4x5-translucent",
        "iso-a4x5-transparent",
        "iso-a4x5-white",
        "iso-a4x6-translucent",
        "iso-a4x6-transparent",
        "iso-a4x6-white",
        "iso-a4x7-translucent",
        "iso-a4x7-transparent",
        "iso-a4x7-white",
        "iso-a4x8-translucent",
        "iso-a4x8-transparent",
        "iso-a4x8-white",
        "iso-a4x9-translucent",
        "iso-a4x9-transparent",
        "iso-a4x9-white",
        "iso-a4xsynchro-translucent",
        "iso-a4xsynchro-transparent",
        "iso-a4xsynchro-white",
        "iso-a5-colored",
        "iso-a5-translucent",
        "iso-a5-transparent",
        "iso-a5-white",
        "iso-a6-white",
        "iso-a7-white",
        "iso-a8-white",
        "iso-a9-white",
        "iso-a10-white",
        "iso-b0-white",
        "iso-b1-white",
        "iso-b2-white",
        "iso-b3-white",
        "iso-b4-colored",
        "iso-b4-white",
        "iso-b5-colored",
        "iso-b5-white",
        "iso-b6-white",
        "iso-b7-white",
        "iso-b8-white",
        "iso-b9-white",
        "iso-b10-white",
        "jis-b0-translucent",
        "jis-b0-transparent",
        "jis-b0-white",
        "jis-b1-translucent",
        "jis-b1-transparent",
        "jis-b1-white",
        "jis-b2-translucent",
        "jis-b2-transparent",
        "jis-b2-white",
        "jis-b3-translucent",
        "jis-b3-transparent",
        "jis-b3-white",
        "jis-b4-colored",
        "jis-b4-translucent",
        "jis-b4-transparent",
        "jis-b4-white",
        "jis-b5-colored",
        "jis-b5-translucent",
        "jis-b5-transparent",
        "jis-b5-white",
        "jis-b6-white",
        "jis-b7-white",
        "jis-b8-white",
        "jis-b9-white",
        "jis-b10-white",
        "ledger-white",
        "na-legal-colored",
        "na-legal-white",
        "na-letter-colored",
        "na-letter-transparent",
        "na-letter-white",
        "quarto-white"
      ],
      "media type": [
        "bond",
        "heavyweight",
        "labels",
        "letterhead",
        "plain",
        "pre-printed",
        "pre-punched",
        "recycled",
        "transparency"
      ],
      "input tray": [
        "bottom",
        "by-pass-tray",
        "envelope",
        "large-capacity",
        "main",
        "manual",
        "middle",
        "side",
        "top",
        "tray-1",
        "tray-2",
        "tray-3",
        "tray-4",
        "tray-5",
        "tray-6",
        "tray-7",
        "tray-8",
        "tray-9",
        "tray-10"
      ],
      "envelope name": [
        "iso-b4-envelope",
        "iso-b5-envelope",
        "iso-c3-envelope",
        "iso-c4-envelope",
        "iso-c5-envelope",
        "iso-c6-envelope",
        "iso-designated-long-envelope",
        "monarch-envelope",
        "na-6x9-envelope",
        "na-7x9-envelope",
        "na-9x11-envelope",
        "na-9x12-envelope",
        "na-10x13-envelope",
        "na-10x14-envelope",
        "na-10x15-envelope",
        "na-number-9-envelope",
        "na-number-10-envelope"
      ]
    };
    var Job_Template_attribute_names = Object.keys(attributes["Job Template"]);
    var Job_Template_and_Operation_attribute_names = Job_Template_attribute_names.concat(Object.keys(attributes["Operation"]));
    var Printer_attribute_names = Object.keys(attributes["Job Template"]).concat(["none"]);
    var media_name_or_size = media["media name"].concat(media["size name"]);
    var keywords = {};
    keywords["compression"] = keyword([
      "compress",
      "deflate",
      "gzip",
      "none"
    ]);
    keywords["compression-supported"] = setof_keyword(
      keywords["compression"]
    );
    keywords["cover-back-supported"] = setof_keyword([
      "cover-type",
      "media",
      "media-col"
    ]);
    keywords["cover-front-supported"] = setof_keyword(
      keywords["cover-back-supported"]
    );
    keywords["cover-type"] = keyword([
      "no-cover",
      "print-back",
      "print-both",
      "print-front",
      "print-none"
    ]);
    keywords["document-digital-signature"] = keyword([
      "dss",
      "none",
      "pgp",
      "smime",
      "xmldsig"
    ]);
    keywords["document-digital-signature-default"] = keyword(
      keywords["document-digital-signature"]
    );
    keywords["document-digital-signature-supported"] = setof_keyword(
      keywords["document-digital-signature"]
    );
    keywords["document-format-details-supported"] = setof_keyword([
      "document-format",
      "document-format-device-id",
      "document-format-version",
      "document-natural-language",
      "document-source-application-name",
      "document-source-application-version",
      "document-source-os-name",
      "document-source-os-version"
    ]);
    keywords["document-format-varying-attributes"] = setof_keyword(
      //Any Printer attribute keyword name
      Printer_attribute_names
    );
    keywords["document-state-reasons"] = setof_keyword([
      "aborted-by-system",
      "canceled-at-device",
      "canceled-by-operator",
      "canceled-by-user",
      "completed-successfully",
      "completed-with-errors",
      "completed-with-warnings",
      "compression-error",
      "data-insufficient",
      "digital-signature-did-not-verify",
      "digital-signature-type-not-supported",
      "digital-signature-wait",
      "document-access-error",
      "document-format-error",
      "document-password-error",
      "document-permission-error",
      "document-security-error",
      "document-unprintable-error",
      "errors-detected",
      "incoming",
      "interpreting",
      "none",
      "outgoing",
      "printing",
      "processing-to-stop-point",
      "queued",
      "queued-for-marker",
      "queued-in-device",
      "resources-are-not-ready",
      "resources-are-not-supported",
      "submission-interrupted",
      "transforming",
      "unsupported-compression",
      "unsupported-document-format",
      "warnings-detected"
    ]);
    keywords["feed-orientation"] = keyword([
      "long-edge-first",
      "short-edge-first"
    ]);
    keywords["feed-orientation-supported"] = setof_keyword(
      keywords["feed-orientation"]
    );
    keywords["finishings-col-supported"] = setof_keyword([
      "finishing-template",
      "stitching"
    ]);
    keywords["identify-actions"] = setof_keyword([
      "display",
      "flash",
      "sound",
      "speak"
    ]);
    keywords["identify-actions-default"] = setof_keyword(
      keywords["identify-actions"]
    );
    keywords["identify-actions-supported"] = setof_keyword(
      keywords["identify-actions"]
    );
    keywords["imposition-template"] = keyword_name([
      "none",
      "signature"
    ]);
    keywords["ipp-features-supported"] = setof_keyword([
      "document-object",
      "ipp-everywhere",
      "job-save",
      "none",
      "page-overrides",
      "proof-print",
      "subscription-object"
    ]);
    keywords["ipp-versions-supported"] = setof_keyword([
      "1.0",
      "1.1",
      "2.0",
      "2.1",
      "2.2"
    ]);
    keywords["job-accounting-sheets-type"] = keyword_name([
      "none",
      "standard"
    ]);
    keywords["job-cover-back-supported"] = setof_keyword(
      keywords["cover-back-supported"]
    );
    keywords["job-cover-front-supported"] = setof_keyword(
      keywords["cover-front-supported"]
    );
    keywords["job-creation-attributes-supported"] = setof_keyword(
      //  Any Job Template attribute
      //  Any job creation Operation attribute keyword name
      Job_Template_and_Operation_attribute_names
    );
    keywords["job-error-action"] = keyword([
      "abort-job",
      "cancel-job",
      "continue-job",
      "suspend-job"
    ]);
    keywords["job-error-action-default"] = keyword(
      keywords["job-error-action"]
    );
    keywords["job-error-action-supported"] = setof_keyword(
      keywords["job-error-action"]
    );
    keywords["job-error-sheet-type"] = keyword_name([
      "none",
      "standard"
    ]);
    keywords["job-error-sheet-when"] = keyword([
      "always",
      "on-error"
    ]);
    keywords["job-finishings-col-supported"] = setof_keyword(
      keywords["finishings-col-supported"]
    );
    keywords["job-hold-until"] = keyword_name([
      "day-time",
      "evening",
      "indefinite",
      "night",
      "no-hold",
      "second-shift",
      "third-shift",
      "weekend"
    ]);
    keywords["job-hold-until-default"] = keyword_name(
      keywords["job-hold-until"]
    );
    keywords["job-hold-until-supported"] = setof_keyword_name(
      keywords["job-hold-until"]
    );
    keywords["job-mandatory-attributes"] = setof_keyword(
      //  Any Job Template attribute
      Job_Template_attribute_names
    );
    keywords["job-password-encryption"] = keyword_name([
      "md2",
      "md4",
      "md5",
      "none",
      "sha"
    ]);
    keywords["job-password-encryption-supported"] = setof_keyword_name(
      keywords["job-password-encryption"]
    );
    keywords["job-save-disposition-supported"] = setof_keyword([
      "save-disposition",
      "save-info"
    ]);
    keywords["job-settable-attributes-supported"] = setof_keyword(
      //  Any Job Template attribute
      Job_Template_attribute_names
    );
    keywords["job-sheets"] = keyword_name([
      "first-print-stream-page",
      "job-both-sheet",
      "job-end-sheet",
      "job-start-sheet",
      "none",
      "standard"
    ]);
    keywords["job-sheets-default"] = keyword_name(
      keywords["job-sheets"]
    );
    keywords["job-sheets-supported"] = setof_keyword_name(
      keywords["job-sheets"]
    );
    keywords["job-spooling-supported"] = keyword([
      "automatic",
      "spool",
      "stream"
    ]);
    keywords["job-state-reasons"] = setof_keyword([
      "aborted-by-system",
      "compression-error",
      "digital-signature-did-not-verify",
      "digital-signature-type-not-supported",
      "document-access-error",
      "document-format-error",
      "document-password-error",
      "document-permission-error",
      "document-security-error",
      "document-unprintable-error",
      "errors-detected",
      "job-canceled-at-device",
      "job-canceled-by-operator",
      "job-canceled-by-user",
      "job-completed-successfully",
      "job-completed-with-errors",
      "job-completed-with-warnings",
      "job-data-insufficient",
      "job-delay-output-until-specified",
      "job-digital-signature-wait",
      "job-hold-until-specified",
      "job-incoming",
      "job-interpreting",
      "job-outgoing",
      "job-password-wait",
      "job-printed-successfully",
      "job-printed-with-errors",
      "job-printed-with-warnings",
      "job-printing",
      "job-queued",
      "job-queued-for-marker",
      "job-restartable",
      "job-resuming",
      "job-saved-successfully",
      "job-saved-with-errors",
      "job-saved-with-warnings",
      "job-saving",
      "job-spooling",
      "job-streaming",
      "job-suspended",
      "job-suspended-by-operator",
      "job-suspended-by-system",
      "job-suspended-by-user",
      "job-suspending",
      "job-transforming",
      "none",
      "printer-stopped",
      "printer-stopped-partly",
      "processing-to-stop-point",
      "queued-in-device",
      "resources-are-not-ready",
      "resources-are-not-supported",
      "service-off-line",
      "submission-interrupted",
      "unsupported-compression",
      "unsupported-document-format",
      "warnings-detected"
    ]);
    keywords["media"] = keyword_name(
      [].concat(
        media["size name"],
        media["media name"],
        media["media type"],
        media["input tray"],
        media["envelope name"]
      )
    );
    keywords["media-back-coating"] = keyword_name([
      "glossy",
      "high-gloss",
      "matte",
      "none",
      "satin",
      "semi-gloss"
    ]);
    keywords["media-back-coating-supported"] = setof_keyword_name(
      keywords["media-back-coating"]
    );
    keywords["media-col-supported"] = setof_keyword([
      "media-bottom-margin",
      "media-left-margin",
      "media-right-margin",
      "media-size-name",
      "media-source",
      "media-top-margin"
    ]);
    keywords["media-color"] = keyword_name([
      "blue",
      "buff",
      "goldenrod",
      "gray",
      "green",
      "ivory",
      "no-color",
      "orange",
      "pink",
      "red",
      "white",
      "yellow"
    ]);
    keywords["media-color-supported"] = setof_keyword_name(
      keywords["media-color"]
    );
    keywords["media-default"] = keyword_name_novalue(
      keywords["media"]
    );
    keywords["media-front-coating"] = keyword_name(
      keywords["media-back-coating"]
    );
    keywords["media-front-coating-supported"] = setof_keyword_name(
      keywords["media-back-coating"]
    );
    keywords["media-grain"] = keyword_name([
      "x-direction",
      "y-direction"
    ]);
    keywords["media-grain-supported"] = setof_keyword_name(
      keywords["media-grain"]
    );
    keywords["media-input-tray-check"] = keyword_name([
      media["input tray"]
    ]);
    keywords["media-input-tray-check-default"] = keyword_name([
      media["input tray"]
    ]);
    keywords["media-input-tray-check-supported"] = setof_keyword_name(
      media["input tray"]
    );
    keywords["media-key"] = keyword_name(
      //  Any "media" media or size keyword value
      media_name_or_size
    );
    keywords["media-key-supported"] = setof_keyword_name([
      //  Any "media" media or size keyword value
      media_name_or_size
    ]);
    keywords["media-pre-printed"] = keyword_name([
      "blank",
      "letter-head",
      "pre-printed"
    ]);
    keywords["media-pre-printed-supported"] = keyword_name(
      keywords["media-pre-printed"]
    );
    keywords["media-ready"] = setof_keyword_name([
      //  Any "media" media or size keyword value
      media_name_or_size
    ]);
    keywords["media-recycled"] = keyword_name([
      "none",
      "standard"
    ]);
    keywords["media-recycled-supported"] = keyword_name(
      keywords["media-recycled"]
    );
    keywords["media-source"] = keyword_name([
      "alternate",
      "alternate-roll",
      "auto",
      "bottom",
      "by-pass-tray",
      "center",
      "disc",
      "envelope",
      "hagaki",
      "large-capacity",
      "left",
      "main",
      "main-roll",
      "manual",
      "middle",
      "photo",
      "rear",
      "right",
      "roll-1",
      "roll-2",
      "roll-3",
      "roll-4",
      "roll-5",
      "roll-6",
      "roll-7",
      "roll-8",
      "roll-9",
      "roll-10",
      "side",
      "top",
      "tray-1",
      "tray-2",
      "tray-3",
      "tray-4",
      "tray-5",
      "tray-6",
      "tray-7",
      "tray-8",
      "tray-9",
      "tray-10",
      "tray-11",
      "tray-12",
      "tray-13",
      "tray-14",
      "tray-15",
      "tray-16",
      "tray-17",
      "tray-18",
      "tray-19",
      "tray-20"
    ]);
    keywords["media-source-feed-direction"] = keyword(
      keywords["feed-orientation"]
    );
    keywords["media-source-supported"] = setof_keyword_name(
      keywords["media-source"]
    );
    keywords["media-supported"] = setof_keyword_name(
      keywords["media"]
    );
    keywords["media-tooth"] = keyword_name([
      "antique",
      "calendared",
      "coarse",
      "fine",
      "linen",
      "medium",
      "smooth",
      "stipple",
      "uncalendared",
      "vellum"
    ]);
    keywords["media-tooth-supported"] = setof_keyword_name(
      keywords["media-tooth"]
    );
    keywords["media-type"] = keyword_name([
      "aluminum",
      "back-print-film",
      "cardboard",
      "cardstock",
      "cd",
      "continuous",
      "continuous-long",
      "continuous-short",
      "corrugated-board",
      "disc",
      "double-wall",
      "dry-film",
      "dvd",
      "embossing-foil",
      "end-board",
      "envelope",
      "envelope-plain",
      "envelope-window",
      "film",
      "flexo-base",
      "flexo-photo-polymer",
      "flute",
      "foil",
      "full-cut-tabs",
      "gravure-cylinder",
      "image-setter-paper",
      "imaging-cylinder",
      "labels",
      "laminating-foil",
      "letterhead",
      "mounting-tape",
      "multi-layer",
      "multi-part-form",
      "other",
      "paper",
      "photographic",
      "photographic-film",
      "photographic-glossy",
      "photographic-high-gloss",
      "photographic-matte",
      "photographic-satin",
      "photographic-semi-gloss",
      "plate",
      "polyester",
      "pre-cut-tabs",
      "roll",
      "screen",
      "screen-paged",
      "self-adhesive",
      "shrink-foil",
      "single-face",
      "single-wall",
      "sleeve",
      "stationery",
      "stationery-coated",
      "stationery-fine",
      "stationery-heavyweight",
      "stationery-inkjet",
      "stationery-letterhead",
      "stationery-lightweight",
      "stationery-preprinted",
      "stationery-prepunched",
      "tab-stock",
      "tractor",
      "transparency",
      "triple-wall",
      "wet-film"
    ]);
    keywords["media-type-supported"] = setof_keyword_name(
      keywords["media-type"]
    );
    keywords["multiple-document-handling"] = keyword([
      "separate-documents-collated-copies",
      "separate-documents-uncollated-copies",
      "single-document",
      "single-document-new-sheet"
    ]);
    keywords["multiple-document-handling-default"] = keyword(
      keywords["multiple-document-handling"]
    );
    keywords["multiple-document-handling-supported"] = setof_keyword(
      keywords["multiple-document-handling"]
    );
    keywords["multiple-operation-timeout-action"] = keyword([
      "abort-job",
      "hold-job",
      "process-job"
    ]);
    keywords["notify-events"] = setof_keyword([
      "job-completed",
      "job-config-changed",
      "job-created",
      "job-progress",
      "job-state-changed",
      "job-stopped",
      "none",
      "printer-config-changed",
      "printer-finishings-changed",
      "printer-media-changed",
      "printer-queue-order-changed",
      "printer-restarted",
      "printer-shutdown",
      "printer-state-changed",
      "printer-stopped"
    ]);
    keywords["notify-events-default"] = setof_keyword(
      keywords["notify-events"]
    );
    keywords["notify-events-supported"] = setof_keyword(
      keywords["notify-events"]
    );
    keywords["notify-pull-method"] = keyword([
      "ippget"
    ]);
    keywords["notify-pull-method-supported"] = setof_keyword(
      keywords["notify-pull-method"]
    );
    keywords["notify-subscribed-event"] = keyword(
      keywords["notify-events"]
    );
    keywords["output-bin"] = keyword_name([
      "bottom",
      "center",
      "face-down",
      "face-up",
      "large-capacity",
      "left",
      "mailbox-1",
      "mailbox-2",
      "mailbox-3",
      "mailbox-4",
      "mailbox-5",
      "mailbox-6",
      "mailbox-7",
      "mailbox-8",
      "mailbox-9",
      "mailbox-10",
      "middle",
      "my-mailbox",
      "rear",
      "right",
      "side",
      "stacker-1",
      "stacker-2",
      "stacker-3",
      "stacker-4",
      "stacker-5",
      "stacker-6",
      "stacker-7",
      "stacker-8",
      "stacker-9",
      "stacker-10",
      "top",
      "tray-1",
      "tray-2",
      "tray-3",
      "tray-4",
      "tray-5",
      "tray-6",
      "tray-7",
      "tray-8",
      "tray-9",
      "tray-10"
    ]);
    keywords["job-accounting-output-bin"] = keyword_name(
      keywords["output-bin"]
    );
    keywords["output-bin-default"] = keyword_name(
      keywords["output-bin"]
    );
    keywords["output-bin-supported"] = setof_keyword_name(
      keywords["output-bin"]
    );
    keywords["page-delivery"] = keyword([
      "reverse-order-face-down",
      "reverse-order-face-up",
      "same-order-face-down",
      "same-order-face-up",
      "system-specified"
    ]);
    keywords["page-delivery-default"] = keyword(
      keywords["page-delivery"]
    );
    keywords["page-delivery-supported"] = setof_keyword(
      keywords["page-delivery"]
    );
    keywords["page-order-received"] = keyword([
      "1-to-n-order",
      "n-to-1-order"
    ]);
    keywords["page-order-received-default"] = keyword(
      keywords["page-order-received"]
    );
    keywords["page-order-received-supported"] = setof_keyword(
      keywords["page-order-received"]
    );
    keywords["current-page-order"] = keyword(
      keywords["page-order-received"]
    );
    keywords["pdl-init-file-supported"] = setof_keyword([
      "pdl-init-file-entry",
      "pdl-init-file-location",
      "pdl-init-file-name"
    ]);
    keywords["pdl-override-supported"] = keyword([
      "attempted",
      "guaranteed",
      "not-attempted"
    ]);
    keywords["presentation-direction-number-up"] = keyword([
      "tobottom-toleft",
      "tobottom-toright",
      "toleft-tobottom",
      "toleft-totop",
      "toright-tobottom",
      "toright-totop",
      "totop-toleft",
      "totop-toright"
    ]);
    keywords["presentation-direction-number-up-default"] = keyword(
      keywords["presentation-direction-number-up"]
    );
    keywords["presentation-direction-number-up-supported"] = setof_keyword(
      keywords["presentation-direction-number-up"]
    );
    keywords["print-color-mode"] = keyword([
      "auto",
      "bi-level",
      "color",
      "highlight",
      "monochrome",
      "process-bi-level",
      "process-monochrome"
    ]);
    keywords["print-color-mode-default"] = keyword(
      keywords["print-color-mode"]
    );
    keywords["print-color-mode-supported"] = setof_keyword(
      keywords["print-color-mode"]
    );
    keywords["print-content-optimize"] = keyword([
      "auto",
      "graphic",
      "photo",
      "text",
      "text-and-graphic"
    ]);
    keywords["print-content-optimize-default"] = keyword(
      keywords["print-content-optimize"]
    );
    keywords["print-content-optimize-supported"] = setof_keyword(
      keywords["print-content-optimize"]
    );
    keywords["print-rendering-intent"] = keyword([
      "absolute",
      "auto",
      "perceptual",
      "relative",
      "relative-bpc",
      "saturation"
    ]);
    keywords["print-rendering-intent-default"] = keyword(
      keywords["print-rendering-intent"]
    );
    keywords["print-rendering-intent-supported"] = setof_keyword(
      keywords["print-rendering-intent"]
    );
    keywords["printer-get-attributes-supported"] = setof_keyword(
      //  Any Job Template attribute
      //  Any job creation Operation attribute keyword name
      Job_Template_and_Operation_attribute_names
    );
    keywords["printer-mandatory-job-attributes"] = setof_keyword(
      //	Any Job Template attribute
      //	Any Operation attribute at the job level
      //this probably isn't quite right...
      Job_Template_and_Operation_attribute_names
    );
    keywords["printer-settable-attributes-supported"] = setof_keyword(
      //  Any read-write Printer attribute keyword name
      Printer_attribute_names
    );
    keywords["printer-state-reasons"] = setof_keyword([
      "alert-removal-of-binary-change-entry",
      "bander-added",
      "bander-almost-empty",
      "bander-almost-full",
      "bander-at-limit",
      "bander-closed",
      "bander-configuration-change",
      "bander-cover-closed",
      "bander-cover-open",
      "bander-empty",
      "bander-full",
      "bander-interlock-closed",
      "bander-interlock-open",
      "bander-jam",
      "bander-life-almost-over",
      "bander-life-over",
      "bander-memory-exhausted",
      "bander-missing",
      "bander-motor-failure",
      "bander-near-limit",
      "bander-offline",
      "bander-opened",
      "bander-over-temperature",
      "bander-power-saver",
      "bander-recoverable-failure",
      "bander-recoverable-storage-error",
      "bander-removed",
      "bander-resource-added",
      "bander-resource-removed",
      "bander-thermistor-failure",
      "bander-timing-failure",
      "bander-turned-off",
      "bander-turned-on",
      "bander-under-temperature",
      "bander-unrecoverable-failure",
      "bander-unrecoverable-storage-error",
      "bander-warming-up",
      "binder-added",
      "binder-almost-empty",
      "binder-almost-full",
      "binder-at-limit",
      "binder-closed",
      "binder-configuration-change",
      "binder-cover-closed",
      "binder-cover-open",
      "binder-empty",
      "binder-full",
      "binder-interlock-closed",
      "binder-interlock-open",
      "binder-jam",
      "binder-life-almost-over",
      "binder-life-over",
      "binder-memory-exhausted",
      "binder-missing",
      "binder-motor-failure",
      "binder-near-limit",
      "binder-offline",
      "binder-opened",
      "binder-over-temperature",
      "binder-power-saver",
      "binder-recoverable-failure",
      "binder-recoverable-storage-error",
      "binder-removed",
      "binder-resource-added",
      "binder-resource-removed",
      "binder-thermistor-failure",
      "binder-timing-failure",
      "binder-turned-off",
      "binder-turned-on",
      "binder-under-temperature",
      "binder-unrecoverable-failure",
      "binder-unrecoverable-storage-error",
      "binder-warming-up",
      "cleaner-life-almost-over",
      "cleaner-life-over",
      "configuration-change",
      "connecting-to-device",
      "cover-open",
      "deactivated",
      "developer-empty",
      "developer-low",
      "die-cutter-added",
      "die-cutter-almost-empty",
      "die-cutter-almost-full",
      "die-cutter-at-limit",
      "die-cutter-closed",
      "die-cutter-configuration-change",
      "die-cutter-cover-closed",
      "die-cutter-cover-open",
      "die-cutter-empty",
      "die-cutter-full",
      "die-cutter-interlock-closed",
      "die-cutter-interlock-open",
      "die-cutter-jam",
      "die-cutter-life-almost-over",
      "die-cutter-life-over",
      "die-cutter-memory-exhausted",
      "die-cutter-missing",
      "die-cutter-motor-failure",
      "die-cutter-near-limit",
      "die-cutter-offline",
      "die-cutter-opened",
      "die-cutter-over-temperature",
      "die-cutter-power-saver",
      "die-cutter-recoverable-failure",
      "die-cutter-recoverable-storage-error",
      "die-cutter-removed",
      "die-cutter-resource-added",
      "die-cutter-resource-removed",
      "die-cutter-thermistor-failure",
      "die-cutter-timing-failure",
      "die-cutter-turned-off",
      "die-cutter-turned-on",
      "die-cutter-under-temperature",
      "die-cutter-unrecoverable-failure",
      "die-cutter-unrecoverable-storage-error",
      "die-cutter-warming-up",
      "door-open",
      "folder-added",
      "folder-almost-empty",
      "folder-almost-full",
      "folder-at-limit",
      "folder-closed",
      "folder-configuration-change",
      "folder-cover-closed",
      "folder-cover-open",
      "folder-empty",
      "folder-full",
      "folder-interlock-closed",
      "folder-interlock-open",
      "folder-jam",
      "folder-life-almost-over",
      "folder-life-over",
      "folder-memory-exhausted",
      "folder-missing",
      "folder-motor-failure",
      "folder-near-limit",
      "folder-offline",
      "folder-opened",
      "folder-over-temperature",
      "folder-power-saver",
      "folder-recoverable-failure",
      "folder-recoverable-storage-error",
      "folder-removed",
      "folder-resource-added",
      "folder-resource-removed",
      "folder-thermistor-failure",
      "folder-timing-failure",
      "folder-turned-off",
      "folder-turned-on",
      "folder-under-temperature",
      "folder-unrecoverable-failure",
      "folder-unrecoverable-storage-error",
      "folder-warming-up",
      "fuser-over-temp",
      "fuser-under-temp",
      "imprinter-added",
      "imprinter-almost-empty",
      "imprinter-almost-full",
      "imprinter-at-limit",
      "imprinter-closed",
      "imprinter-configuration-change",
      "imprinter-cover-closed",
      "imprinter-cover-open",
      "imprinter-empty",
      "imprinter-full",
      "imprinter-interlock-closed",
      "imprinter-interlock-open",
      "imprinter-jam",
      "imprinter-life-almost-over",
      "imprinter-life-over",
      "imprinter-memory-exhausted",
      "imprinter-missing",
      "imprinter-motor-failure",
      "imprinter-near-limit",
      "imprinter-offline",
      "imprinter-opened",
      "imprinter-over-temperature",
      "imprinter-power-saver",
      "imprinter-recoverable-failure",
      "imprinter-recoverable-storage-error",
      "imprinter-removed",
      "imprinter-resource-added",
      "imprinter-resource-removed",
      "imprinter-thermistor-failure",
      "imprinter-timing-failure",
      "imprinter-turned-off",
      "imprinter-turned-on",
      "imprinter-under-temperature",
      "imprinter-unrecoverable-failure",
      "imprinter-unrecoverable-storage-error",
      "imprinter-warming-up",
      "input-cannot-feed-size-selected",
      "input-manual-input-request",
      "input-media-color-change",
      "input-media-form-parts-change",
      "input-media-size-change",
      "input-media-type-change",
      "input-media-weight-change",
      "input-tray-elevation-failure",
      "input-tray-missing",
      "input-tray-position-failure",
      "inserter-added",
      "inserter-almost-empty",
      "inserter-almost-full",
      "inserter-at-limit",
      "inserter-closed",
      "inserter-configuration-change",
      "inserter-cover-closed",
      "inserter-cover-open",
      "inserter-empty",
      "inserter-full",
      "inserter-interlock-closed",
      "inserter-interlock-open",
      "inserter-jam",
      "inserter-life-almost-over",
      "inserter-life-over",
      "inserter-memory-exhausted",
      "inserter-missing",
      "inserter-motor-failure",
      "inserter-near-limit",
      "inserter-offline",
      "inserter-opened",
      "inserter-over-temperature",
      "inserter-power-saver",
      "inserter-recoverable-failure",
      "inserter-recoverable-storage-error",
      "inserter-removed",
      "inserter-resource-added",
      "inserter-resource-removed",
      "inserter-thermistor-failure",
      "inserter-timing-failure",
      "inserter-turned-off",
      "inserter-turned-on",
      "inserter-under-temperature",
      "inserter-unrecoverable-failure",
      "inserter-unrecoverable-storage-error",
      "inserter-warming-up",
      "interlock-closed",
      "interlock-open",
      "interpreter-cartridge-added",
      "interpreter-cartridge-deleted",
      "interpreter-complex-page-encountered",
      "interpreter-memory-decrease",
      "interpreter-memory-increase",
      "interpreter-resource-added",
      "interpreter-resource-deleted",
      "interpreter-resource-unavailable",
      "make-envelope-added",
      "make-envelope-almost-empty",
      "make-envelope-almost-full",
      "make-envelope-at-limit",
      "make-envelope-closed",
      "make-envelope-configuration-change",
      "make-envelope-cover-closed",
      "make-envelope-cover-open",
      "make-envelope-empty",
      "make-envelope-full",
      "make-envelope-interlock-closed",
      "make-envelope-interlock-open",
      "make-envelope-jam",
      "make-envelope-life-almost-over",
      "make-envelope-life-over",
      "make-envelope-memory-exhausted",
      "make-envelope-missing",
      "make-envelope-motor-failure",
      "make-envelope-near-limit",
      "make-envelope-offline",
      "make-envelope-opened",
      "make-envelope-over-temperature",
      "make-envelope-power-saver",
      "make-envelope-recoverable-failure",
      "make-envelope-recoverable-storage-error",
      "make-envelope-removed",
      "make-envelope-resource-added",
      "make-envelope-resource-removed",
      "make-envelope-thermistor-failure",
      "make-envelope-timing-failure",
      "make-envelope-turned-off",
      "make-envelope-turned-on",
      "make-envelope-under-temperature",
      "make-envelope-unrecoverable-failure",
      "make-envelope-unrecoverable-storage-error",
      "make-envelope-warming-up",
      "marker-adjusting-print-quality",
      "marker-developer-almost-empty",
      "marker-developer-empty",
      "marker-fuser-thermistor-failure",
      "marker-fuser-timing-failure",
      "marker-ink-almost-empty",
      "marker-ink-empty",
      "marker-print-ribbon-almost-empty",
      "marker-print-ribbon-empty",
      "marker-supply-empty",
      "marker-supply-low",
      "marker-toner-cartridge-missing",
      "marker-waste-almost-full",
      "marker-waste-full",
      "marker-waste-ink-receptacle-almost-full",
      "marker-waste-ink-receptacle-full",
      "marker-waste-toner-receptacle-almost-full",
      "marker-waste-toner-receptacle-full",
      "media-empty",
      "media-jam",
      "media-low",
      "media-needed",
      "media-path-cannot-duplex-media-selected",
      "media-path-media-tray-almost-full",
      "media-path-media-tray-full",
      "media-path-media-tray-missing",
      "moving-to-paused",
      "none",
      "opc-life-over",
      "opc-near-eol",
      "other",
      "output-area-almost-full",
      "output-area-full",
      "output-mailbox-select-failure",
      "output-tray-missing",
      "paused",
      "perforater-added",
      "perforater-almost-empty",
      "perforater-almost-full",
      "perforater-at-limit",
      "perforater-closed",
      "perforater-configuration-change",
      "perforater-cover-closed",
      "perforater-cover-open",
      "perforater-empty",
      "perforater-full",
      "perforater-interlock-closed",
      "perforater-interlock-open",
      "perforater-jam",
      "perforater-life-almost-over",
      "perforater-life-over",
      "perforater-memory-exhausted",
      "perforater-missing",
      "perforater-motor-failure",
      "perforater-near-limit",
      "perforater-offline",
      "perforater-opened",
      "perforater-over-temperature",
      "perforater-power-saver",
      "perforater-recoverable-failure",
      "perforater-recoverable-storage-error",
      "perforater-removed",
      "perforater-resource-added",
      "perforater-resource-removed",
      "perforater-thermistor-failure",
      "perforater-timing-failure",
      "perforater-turned-off",
      "perforater-turned-on",
      "perforater-under-temperature",
      "perforater-unrecoverable-failure",
      "perforater-unrecoverable-storage-error",
      "perforater-warming-up",
      "power-down",
      "power-up",
      "printer-manual-reset",
      "printer-nms-reset",
      "printer-ready-to-print",
      "puncher-added",
      "puncher-almost-empty",
      "puncher-almost-full",
      "puncher-at-limit",
      "puncher-closed",
      "puncher-configuration-change",
      "puncher-cover-closed",
      "puncher-cover-open",
      "puncher-empty",
      "puncher-full",
      "puncher-interlock-closed",
      "puncher-interlock-open",
      "puncher-jam",
      "puncher-life-almost-over",
      "puncher-life-over",
      "puncher-memory-exhausted",
      "puncher-missing",
      "puncher-motor-failure",
      "puncher-near-limit",
      "puncher-offline",
      "puncher-opened",
      "puncher-over-temperature",
      "puncher-power-saver",
      "puncher-recoverable-failure",
      "puncher-recoverable-storage-error",
      "puncher-removed",
      "puncher-resource-added",
      "puncher-resource-removed",
      "puncher-thermistor-failure",
      "puncher-timing-failure",
      "puncher-turned-off",
      "puncher-turned-on",
      "puncher-under-temperature",
      "puncher-unrecoverable-failure",
      "puncher-unrecoverable-storage-error",
      "puncher-warming-up",
      "separation-cutter-added",
      "separation-cutter-almost-empty",
      "separation-cutter-almost-full",
      "separation-cutter-at-limit",
      "separation-cutter-closed",
      "separation-cutter-configuration-change",
      "separation-cutter-cover-closed",
      "separation-cutter-cover-open",
      "separation-cutter-empty",
      "separation-cutter-full",
      "separation-cutter-interlock-closed",
      "separation-cutter-interlock-open",
      "separation-cutter-jam",
      "separation-cutter-life-almost-over",
      "separation-cutter-life-over",
      "separation-cutter-memory-exhausted",
      "separation-cutter-missing",
      "separation-cutter-motor-failure",
      "separation-cutter-near-limit",
      "separation-cutter-offline",
      "separation-cutter-opened",
      "separation-cutter-over-temperature",
      "separation-cutter-power-saver",
      "separation-cutter-recoverable-failure",
      "separation-cutter-recoverable-storage-error",
      "separation-cutter-removed",
      "separation-cutter-resource-added",
      "separation-cutter-resource-removed",
      "separation-cutter-thermistor-failure",
      "separation-cutter-timing-failure",
      "separation-cutter-turned-off",
      "separation-cutter-turned-on",
      "separation-cutter-under-temperature",
      "separation-cutter-unrecoverable-failure",
      "separation-cutter-unrecoverable-storage-error",
      "separation-cutter-warming-up",
      "sheet-rotator-added",
      "sheet-rotator-almost-empty",
      "sheet-rotator-almost-full",
      "sheet-rotator-at-limit",
      "sheet-rotator-closed",
      "sheet-rotator-configuration-change",
      "sheet-rotator-cover-closed",
      "sheet-rotator-cover-open",
      "sheet-rotator-empty",
      "sheet-rotator-full",
      "sheet-rotator-interlock-closed",
      "sheet-rotator-interlock-open",
      "sheet-rotator-jam",
      "sheet-rotator-life-almost-over",
      "sheet-rotator-life-over",
      "sheet-rotator-memory-exhausted",
      "sheet-rotator-missing",
      "sheet-rotator-motor-failure",
      "sheet-rotator-near-limit",
      "sheet-rotator-offline",
      "sheet-rotator-opened",
      "sheet-rotator-over-temperature",
      "sheet-rotator-power-saver",
      "sheet-rotator-recoverable-failure",
      "sheet-rotator-recoverable-storage-error",
      "sheet-rotator-removed",
      "sheet-rotator-resource-added",
      "sheet-rotator-resource-removed",
      "sheet-rotator-thermistor-failure",
      "sheet-rotator-timing-failure",
      "sheet-rotator-turned-off",
      "sheet-rotator-turned-on",
      "sheet-rotator-under-temperature",
      "sheet-rotator-unrecoverable-failure",
      "sheet-rotator-unrecoverable-storage-error",
      "sheet-rotator-warming-up",
      "shutdown",
      "slitter-added",
      "slitter-almost-empty",
      "slitter-almost-full",
      "slitter-at-limit",
      "slitter-closed",
      "slitter-configuration-change",
      "slitter-cover-closed",
      "slitter-cover-open",
      "slitter-empty",
      "slitter-full",
      "slitter-interlock-closed",
      "slitter-interlock-open",
      "slitter-jam",
      "slitter-life-almost-over",
      "slitter-life-over",
      "slitter-memory-exhausted",
      "slitter-missing",
      "slitter-motor-failure",
      "slitter-near-limit",
      "slitter-offline",
      "slitter-opened",
      "slitter-over-temperature",
      "slitter-power-saver",
      "slitter-recoverable-failure",
      "slitter-recoverable-storage-error",
      "slitter-removed",
      "slitter-resource-added",
      "slitter-resource-removed",
      "slitter-thermistor-failure",
      "slitter-timing-failure",
      "slitter-turned-off",
      "slitter-turned-on",
      "slitter-under-temperature",
      "slitter-unrecoverable-failure",
      "slitter-unrecoverable-storage-error",
      "slitter-warming-up",
      "spool-area-full",
      "stacker-added",
      "stacker-almost-empty",
      "stacker-almost-full",
      "stacker-at-limit",
      "stacker-closed",
      "stacker-configuration-change",
      "stacker-cover-closed",
      "stacker-cover-open",
      "stacker-empty",
      "stacker-full",
      "stacker-interlock-closed",
      "stacker-interlock-open",
      "stacker-jam",
      "stacker-life-almost-over",
      "stacker-life-over",
      "stacker-memory-exhausted",
      "stacker-missing",
      "stacker-motor-failure",
      "stacker-near-limit",
      "stacker-offline",
      "stacker-opened",
      "stacker-over-temperature",
      "stacker-power-saver",
      "stacker-recoverable-failure",
      "stacker-recoverable-storage-error",
      "stacker-removed",
      "stacker-resource-added",
      "stacker-resource-removed",
      "stacker-thermistor-failure",
      "stacker-timing-failure",
      "stacker-turned-off",
      "stacker-turned-on",
      "stacker-under-temperature",
      "stacker-unrecoverable-failure",
      "stacker-unrecoverable-storage-error",
      "stacker-warming-up",
      "stapler-added",
      "stapler-almost-empty",
      "stapler-almost-full",
      "stapler-at-limit",
      "stapler-closed",
      "stapler-configuration-change",
      "stapler-cover-closed",
      "stapler-cover-open",
      "stapler-empty",
      "stapler-full",
      "stapler-interlock-closed",
      "stapler-interlock-open",
      "stapler-jam",
      "stapler-life-almost-over",
      "stapler-life-over",
      "stapler-memory-exhausted",
      "stapler-missing",
      "stapler-motor-failure",
      "stapler-near-limit",
      "stapler-offline",
      "stapler-opened",
      "stapler-over-temperature",
      "stapler-power-saver",
      "stapler-recoverable-failure",
      "stapler-recoverable-storage-error",
      "stapler-removed",
      "stapler-resource-added",
      "stapler-resource-removed",
      "stapler-thermistor-failure",
      "stapler-timing-failure",
      "stapler-turned-off",
      "stapler-turned-on",
      "stapler-under-temperature",
      "stapler-unrecoverable-failure",
      "stapler-unrecoverable-storage-error",
      "stapler-warming-up",
      "stitcher-added",
      "stitcher-almost-empty",
      "stitcher-almost-full",
      "stitcher-at-limit",
      "stitcher-closed",
      "stitcher-configuration-change",
      "stitcher-cover-closed",
      "stitcher-cover-open",
      "stitcher-empty",
      "stitcher-full",
      "stitcher-interlock-closed",
      "stitcher-interlock-open",
      "stitcher-jam",
      "stitcher-life-almost-over",
      "stitcher-life-over",
      "stitcher-memory-exhausted",
      "stitcher-missing",
      "stitcher-motor-failure",
      "stitcher-near-limit",
      "stitcher-offline",
      "stitcher-opened",
      "stitcher-over-temperature",
      "stitcher-power-saver",
      "stitcher-recoverable-failure",
      "stitcher-recoverable-storage-error",
      "stitcher-removed",
      "stitcher-resource-added",
      "stitcher-resource-removed",
      "stitcher-thermistor-failure",
      "stitcher-timing-failure",
      "stitcher-turned-off",
      "stitcher-turned-on",
      "stitcher-under-temperature",
      "stitcher-unrecoverable-failure",
      "stitcher-unrecoverable-storage-error",
      "stitcher-warming-up",
      "stopped-partly",
      "stopping",
      "subunit-added",
      "subunit-almost-empty",
      "subunit-almost-full",
      "subunit-at-limit",
      "subunit-closed",
      "subunit-empty",
      "subunit-full",
      "subunit-life-almost-over",
      "subunit-life-over",
      "subunit-memory-exhausted",
      "subunit-missing",
      "subunit-motor-failure",
      "subunit-near-limit",
      "subunit-offline",
      "subunit-opened",
      "subunit-over-temperature",
      "subunit-power-saver",
      "subunit-recoverable-failure",
      "subunit-recoverable-storage-error",
      "subunit-removed",
      "subunit-resource-added",
      "subunit-resource-removed",
      "subunit-thermistor-failure",
      "subunit-timing-Failure",
      "subunit-turned-off",
      "subunit-turned-on",
      "subunit-under-temperature",
      "subunit-unrecoverable-failure",
      "subunit-unrecoverable-storage-error",
      "subunit-warming-up",
      "timed-out",
      "toner-empty",
      "toner-low",
      "trimmer-added",
      "trimmer-added",
      "trimmer-almost-empty",
      "trimmer-almost-empty",
      "trimmer-almost-full",
      "trimmer-almost-full",
      "trimmer-at-limit",
      "trimmer-at-limit",
      "trimmer-closed",
      "trimmer-closed",
      "trimmer-configuration-change",
      "trimmer-configuration-change",
      "trimmer-cover-closed",
      "trimmer-cover-closed",
      "trimmer-cover-open",
      "trimmer-cover-open",
      "trimmer-empty",
      "trimmer-empty",
      "trimmer-full",
      "trimmer-full",
      "trimmer-interlock-closed",
      "trimmer-interlock-closed",
      "trimmer-interlock-open",
      "trimmer-interlock-open",
      "trimmer-jam",
      "trimmer-jam",
      "trimmer-life-almost-over",
      "trimmer-life-almost-over",
      "trimmer-life-over",
      "trimmer-life-over",
      "trimmer-memory-exhausted",
      "trimmer-memory-exhausted",
      "trimmer-missing",
      "trimmer-missing",
      "trimmer-motor-failure",
      "trimmer-motor-failure",
      "trimmer-near-limit",
      "trimmer-near-limit",
      "trimmer-offline",
      "trimmer-offline",
      "trimmer-opened",
      "trimmer-opened",
      "trimmer-over-temperature",
      "trimmer-over-temperature",
      "trimmer-power-saver",
      "trimmer-power-saver",
      "trimmer-recoverable-failure",
      "trimmer-recoverable-failure",
      "trimmer-recoverable-storage-error",
      "trimmer-removed",
      "trimmer-resource-added",
      "trimmer-resource-removed",
      "trimmer-thermistor-failure",
      "trimmer-timing-failure",
      "trimmer-turned-off",
      "trimmer-turned-on",
      "trimmer-under-temperature",
      "trimmer-unrecoverable-failure",
      "trimmer-unrecoverable-storage-error",
      "trimmer-warming-up",
      "unknown",
      "wrapper-added",
      "wrapper-almost-empty",
      "wrapper-almost-full",
      "wrapper-at-limit",
      "wrapper-closed",
      "wrapper-configuration-change",
      "wrapper-cover-closed",
      "wrapper-cover-open",
      "wrapper-empty",
      "wrapper-full",
      "wrapper-interlock-closed",
      "wrapper-interlock-open",
      "wrapper-jam",
      "wrapper-life-almost-over",
      "wrapper-life-over",
      "wrapper-memory-exhausted",
      "wrapper-missing",
      "wrapper-motor-failure",
      "wrapper-near-limit",
      "wrapper-offline",
      "wrapper-opened",
      "wrapper-over-temperature",
      "wrapper-power-saver",
      "wrapper-recoverable-failure",
      "wrapper-recoverable-storage-error",
      "wrapper-removed",
      "wrapper-resource-added",
      "wrapper-resource-removed",
      "wrapper-thermistor-failure",
      "wrapper-timing-failure",
      "wrapper-turned-off",
      "wrapper-turned-on",
      "wrapper-under-temperature",
      "wrapper-unrecoverable-failure",
      "wrapper-unrecoverable-storage-error",
      "wrapper-warming-up"
    ]);
    keywords["proof-print-supported"] = setof_keyword([
      "media",
      "media-col",
      "proof-print-copies"
    ]);
    keywords["pwg-raster-document-sheet-back"] = keyword([
      "flipped",
      "manual-tumble",
      "normal",
      "rotated"
    ]);
    keywords["pwg-raster-document-type-supported"] = setof_keyword([
      "adobe-rgb_8",
      "adobe-rgb_16",
      "black_1",
      "black_8",
      "black_16",
      "cmyk_8",
      "cmyk_16",
      "device1_8",
      "device1_16",
      "device2_8",
      "device2_16",
      "device3_8",
      "device3_16",
      "device4_8",
      "device4_16",
      "device5_8",
      "device5_16",
      "device6_8",
      "device6_16",
      "device7_8",
      "device7_16",
      "device8_8",
      "device8_16",
      "device9_8",
      "device9_16",
      "device10_8",
      "device10_16",
      "device11_8",
      "device11_16",
      "device12_8",
      "device12_16",
      "device13_8",
      "device13_16",
      "device14_8",
      "device14_16",
      "device15_8",
      "device15_16",
      "rgb_8",
      "rgb_16",
      "sgray_1",
      "sgray_8",
      "sgray_16",
      "srgb_8",
      "srgb_16"
    ]);
    keywords["requested-attributes"] = keyword([
      "all",
      "document-description",
      "document-template",
      "job-description",
      "job-template",
      "printer-description",
      "subscription-description",
      "subscription-template"
    ]);
    keywords["save-disposition"] = keyword([
      "none",
      "print-save",
      "save-only"
    ]);
    keywords["save-disposition-supported"] = setof_keyword(
      keywords["save-disposition"]
    );
    keywords["save-info-supported"] = setof_keyword([
      "save-document-format",
      "save-location",
      "save-name"
    ]);
    keywords["separator-sheets-type"] = keyword_name([
      "both-sheets",
      "end-sheet",
      "none",
      "slip-sheets",
      "start-sheet"
    ]);
    keywords["separator-sheets-type-supported"] = setof_keyword_name(
      keywords["separator-sheets-type"]
    );
    keywords["sheet-collate"] = keyword([
      "collated",
      "uncollated"
    ]);
    keywords["sheet-collate-default"] = keyword(
      keywords["sheet-collate"]
    );
    keywords["sheet-collate-supported"] = setof_keyword(
      keywords["sheet-collate"]
    );
    keywords["sides"] = keyword([
      "one-sided",
      "two-sided-long-edge",
      "two-sided-short-edge"
    ]);
    keywords["sides-default"] = keyword(
      keywords["sides"]
    );
    keywords["sides-supported"] = setof_keyword(
      keywords["sides"]
    );
    keywords["stitching-reference-edge"] = keyword([
      "bottom",
      "left",
      "right",
      "top"
    ]);
    keywords["stitching-reference-edge-supported"] = setof_keyword(
      keywords["stitching-reference-edge"]
    );
    keywords["stitching-supported"] = setof_keyword([
      "stitching-locations",
      "stitching-offset",
      "stitching-reference-edge"
    ]);
    keywords["uri-authentication-supported"] = setof_keyword([
      "basic",
      "certificate",
      "digest",
      "negotiate",
      "none",
      "requesting-user-name"
    ]);
    keywords["uri-security-supported"] = setof_keyword([
      "none",
      "ssl3",
      "tls"
    ]);
    keywords["which-jobs"] = keyword([
      "aborted",
      "all",
      "canceled",
      "completed",
      "not-completed",
      "pending",
      "pending-held",
      "processing",
      "processing-stopped",
      "proof-print",
      "saved"
    ]);
    keywords["which-jobs-supported"] = setof_keyword(
      keywords["which-jobs"]
    );
    keywords["x-image-position"] = keyword([
      "center",
      "left",
      "none",
      "right"
    ]);
    keywords["x-image-position-default"] = keyword(
      keywords["x-image-position"]
    );
    keywords["x-image-position-supported"] = setof_keyword(
      keywords["x-image-position"]
    );
    keywords["xri-authentication-supported"] = setof_keyword([
      "basic",
      "certificate",
      "digest",
      "none",
      "requesting-user-name"
    ]);
    keywords["xri-security-supported"] = setof_keyword([
      "none",
      "ssl3",
      "tls"
    ]);
    keywords["y-image-position"] = keyword([
      "bottom",
      "center",
      "none",
      "top"
    ]);
    keywords["y-image-position-default"] = keyword(
      keywords["y-image-position"]
    );
    keywords["y-image-position-supported"] = setof_keyword(
      keywords["y-image-position"]
    );
    module.exports = keywords;
  }
});

// node_modules/ipp/lib/serializer.js
var require_serializer = __commonJS({
  "node_modules/ipp/lib/serializer.js"(exports, module) {
    var operations = require_enums()["operations-supported"];
    var tags = require_tags();
    var versions = require_versions();
    var attributes = require_attributes();
    var enums = require_enums();
    var keywords = require_keywords();
    var statusCodes = require_status_codes();
    var RS = "";
    function random() {
      return +Math.random().toString().substr(-8);
    }
    module.exports = function serializer(msg) {
      var buf = new Buffer(10240);
      var position = 0;
      function write1(val) {
        checkBufferSize(1);
        buf.writeUInt8(val, position);
        position += 1;
      }
      function write2(val) {
        checkBufferSize(2);
        buf.writeUInt16BE(val, position);
        position += 2;
      }
      function write4(val) {
        checkBufferSize(4);
        buf.writeUInt32BE(val, position);
        position += 4;
      }
      function write(str, enc) {
        var length = Buffer.byteLength(str);
        write2(length);
        checkBufferSize(length);
        buf.write(str, position, length, enc || "utf8");
        position += length;
      }
      function checkBufferSize(length) {
        if (position + length > buf.length) {
          buf = Buffer.concat([buf], 2 * buf.length);
        }
      }
      var special = { "attributes-charset": 1, "attributes-natural-language": 2 };
      var groupmap = {
        "job-attributes-tag": ["Job Template", "Job Description"],
        "operation-attributes-tag": "Operation",
        "printer-attributes-tag": "Printer Description",
        "unsupported-attributes-tag": "",
        //??
        "subscription-attributes-tag": "Subscription Description",
        "event-notification-attributes-tag": "Event Notifications",
        "resource-attributes-tag": "",
        //??
        "document-attributes-tag": "Document Description"
      };
      function writeGroup(tag) {
        var attrs = msg[tag];
        if (!attrs) return;
        var keys = Object.keys(attrs);
        if (tag == tags["operation-attributes-tag"])
          keys = keys.sort(function(a, b) {
            return (special[a] || 3) - (special[b] || 3);
          });
        var groupname = groupmap[tag];
        write1(tags[tag]);
        keys.forEach(function(name) {
          attr(groupname, name, attrs);
        });
      }
      function attr(group, name, obj) {
        var groupName = Array.isArray(group) ? group.find(function(grp) {
          return attributes[grp][name];
        }) : group;
        if (!groupName) throw "Unknown attribute: " + name;
        var syntax = attributes[groupName][name];
        if (!syntax) throw "Unknown attribute: " + name;
        var value = obj[name];
        if (!Array.isArray(value))
          value = [value];
        value.forEach(function(value2, i) {
          var syntax2 = Array.isArray(syntax) ? resolveAlternates(syntax, name, value2) : syntax;
          var tag = getTag(syntax2, name, value2);
          if (tag === tags.enum)
            value2 = enums[name][value2];
          write1(tag);
          if (i == 0) {
            write(name);
          } else {
            write2(0);
          }
          writeValue(tag, value2, syntax2.members);
        });
      }
      function getTag(syntax, name, value) {
        var tag = syntax.tag;
        if (!tag) {
          var hasRS = !!~value.indexOf(RS);
          tag = tags[syntax.type + (hasRS ? "With" : "Without") + "Language"];
        }
        return tag;
      }
      function resolveAlternates(array, name, value) {
        switch (array.alts) {
          case "keyword,name":
          case "keyword,name,novalue":
            if (value === null && array.lookup["novalue"]) return array.lookup["novalue"];
            return ~keywords[name].indexOf(value) ? array.lookup.keyword : array.lookup.name;
          case "integer,rangeOfInteger":
            return Array.isArray(value) ? array.lookup.rangeOfInteger : array.lookup.integer;
          case "dateTime,novalue":
            return !IsNaN(date.parse(value)) ? array.lookup.dateTime : array.lookup["novalue"];
          case "integer,novalue":
            return !IsNaN(value) ? array.lookup.integer : array.lookup["novalue"];
          case "name,novalue":
            return value !== null ? array.lookup.name : array.lookup["novalue"];
          case "novalue,uri":
            return value !== null ? array.lookup.uri : array.lookup["novalue"];
          case "enumeration,unknown":
            return enums[name][value] ? array.lookup["enumeration"] : array.lookup.unknown;
          case "enumeration,novalue":
            return value !== null ? array.lookup["enumeration"] : array.lookup["novalue"];
          case "collection,novalue":
            return value !== null ? array.lookup["enumeration"] : array.lookup["novalue"];
          default:
            throw "Unknown atlernates";
        }
      }
      function writeValue(tag, value, submembers) {
        switch (tag) {
          case tags.enum:
            write2(4);
            return write4(value);
          case tags.integer:
            write2(4);
            return write4(value);
          case tags.boolean:
            write2(1);
            return write1(Number(value));
          case tags.rangeOfInteger:
            write2(8);
            write4(value[0]);
            write4(value[1]);
            return;
          case tags.resolution:
            write2(9);
            write4(value[0]);
            write4(value[1]);
            write1(value[2] === "dpi" ? 3 : 4);
            return;
          case tags.dateTime:
            write2(11);
            write2(value.getFullYear());
            write1(value.getMonth());
            write1(value.getDate());
            write1(value.getHours());
            write1(value.getMinutes());
            write1(value.getSeconds());
            write1(value.getMilliseconds());
            var tz = timezone(value);
            write1(tz[0]);
            write1(tz[1]);
            write1(tz[2]);
            return;
          case tags.textWithLanguage:
          case tags.nameWithLanguage:
            write2(parts[0].length);
            write2(parts[0]);
            write2(parts[1].length);
            write2(parts[1]);
            return;
          case tags.nameWithoutLanguage:
          case tags.textWithoutLanguage:
          case tags.octetString:
          case tags.memberAttrName:
            return write(value);
          case tags.keyword:
          case tags.uri:
          case tags.uriScheme:
          case tags.charset:
          case tags.naturalLanguage:
          case tags.mimeMediaType:
            return write(value, "ascii");
          case tags.begCollection:
            write2(0);
            return writeCollection(value, submembers);
          case tags["no-value"]:
            return write2(0);
          default:
            debugger;
            console.error(tag, "not handled");
        }
      }
      function writeCollection(value, members) {
        Object.keys(value).forEach(function(key) {
          var subvalue = value[key];
          var subsyntax = members[key];
          if (Array.isArray(subsyntax))
            subsyntax = resolveAlternates(subsyntax, key, subvalue);
          var tag = getTag(subsyntax, key, subvalue);
          if (tag === tags.enum)
            subvalue = enums[key][subvalue];
          write1(tags.memberAttrName);
          write2(0);
          writeValue(tags.memberAttrName, key);
          write1(tag);
          write2(0);
          writeValue(tag, subvalue, subsyntax.members);
        });
        write1(tags.endCollection);
        write2(0);
        write2(0);
      }
      write2(versions[msg.version || "2.0"]);
      write2(msg.operation ? operations[msg.operation] : statusCodes[msg.statusCode]);
      write4(msg.id || random());
      writeGroup("operation-attributes-tag");
      writeGroup("job-attributes-tag");
      writeGroup("printer-attributes-tag");
      writeGroup("document-attributes-tag");
      write1(3);
      if (!msg.data)
        return buf.slice(0, position);
      if (!Buffer.isBuffer(msg.data))
        throw "data must be a Buffer";
      var buf2 = new Buffer(position + msg.data.length);
      buf.copy(buf2, 0, 0, position);
      msg.data.copy(buf2, position, 0);
      return buf2;
    };
    function timezone(d) {
      var z = d.getTimezoneOffset();
      return [
        z > 0 ? "-" : "+",
        ~~(Math.abs(z) / 60),
        Math.abs(z) % 60
      ];
    }
  }
});

// node_modules/ipp/lib/request.js
var require_request = __commonJS({
  "node_modules/ipp/lib/request.js"(exports, module) {
    var http = __require("http");
    var https = __require("https");
    var url = __require("url");
    var parse = require_parser();
    module.exports = function(opts, buffer, cb) {
      var streamed = typeof buffer === "function";
      if (!Buffer.isBuffer(buffer) || buffer.length < 10) {
        return cb(new Error("Data required"));
      }
      if (typeof opts === "string")
        opts = url.parse(opts);
      if (!opts.port) opts.port = 631;
      if (!opts.headers) opts.headers = {};
      opts.headers["Content-Type"] = "application/ipp";
      opts.method = "POST";
      if (opts.protocol === "ipp:")
        opts.protocol = "http:";
      if (opts.protocol === "ipps:")
        opts.protocol = "https:";
      var req = (opts.protocol === "https:" ? https : http).request(opts, function(res) {
        switch (res.statusCode) {
          case 100:
            if (opts.headers["Expect"] !== "100-Continue" || typeof opts.continue !== "function") {
              cb(new IppResponseError(res.statusCode));
            }
            return console.log("100 Continue");
          case 200:
            return readResponse(res, cb);
          default:
            cb(new IppResponseError(res.statusCode));
            return console.log(res.statusCode, "response");
        }
      });
      req.on("error", function(err) {
        cb(err);
      });
      if (opts.headers["Expect"] === "100-Continue" && typeof opts.continue === "function") {
        req.on("continue", function() {
          opts.continue(req);
        });
      }
      req.write(buffer);
      req.end();
    };
    function readResponse(res, cb) {
      var chunks = [], length = 0;
      res.on("data", function(chunk) {
        length += chunk.length;
        chunks.push(chunk);
      });
      res.on("end", function() {
        var response = parse(Buffer.concat(chunks, length));
        delete response.operation;
        cb(null, response);
      });
    }
    function IppResponseError(statusCode, message) {
      this.name = "IppResponseError";
      this.statusCode = statusCode;
      this.message = message || "Received unexpected response status " + statusCode + " from the printer";
      this.stack = new Error().stack;
    }
    IppResponseError.prototype = Object.create(Error.prototype);
    IppResponseError.prototype.constructor = IppResponseError;
  }
});

// node_modules/ipp/lib/printer.js
var require_printer = __commonJS({
  "node_modules/ipp/lib/printer.js"(exports, module) {
    var request = require_request();
    var serialize = require_serializer();
    var extend = require_ipputil().extend;
    var parseurl = __require("url").parse;
    function Printer2(url, opts) {
      if (!(this instanceof Printer2)) return new Printer2(url, opts);
      opts = opts || {};
      this.url = typeof url === "string" ? parseurl(url) : url;
      this.version = opts.version || "2.0";
      this.uri = opts.uri || "ipp://" + this.url.host + this.url.path;
      this.charset = opts.charset || "utf-8";
      this.language = opts.language || "en-us";
    }
    Printer2.prototype = {
      _message: function(operation, msg) {
        if (typeof operation === "undefined") operation = "Get-Printer-Attributes";
        var base = {
          version: this.version,
          operation,
          id: null,
          //will get added by serializer if one isn't given
          "operation-attributes-tag": {
            //these are required to be in this order
            "attributes-charset": this.charset,
            "attributes-natural-language": this.language,
            "printer-uri": this.uri
          }
        };
        if (msg && msg["operation-attributes-tag"]["job-id"])
          base["operation-attributes-tag"]["job-id"] = msg["operation-attributes-tag"]["job-id"];
        else if (msg && msg["operation-attributes-tag"]["job-uri"])
          base["operation-attributes-tag"]["job-uri"] = msg["operation-attributes-tag"]["job-uri"];
        msg = extend(base, msg);
        if (msg["operation-attributes-tag"]["job-uri"])
          delete msg["operation-attributes-tag"]["printer-uri"];
        return msg;
      },
      execute: function(operation, msg, cb) {
        msg = this._message(operation, msg);
        var buf = serialize(msg);
        request(this.url, buf, cb);
      }
    };
    module.exports = Printer2;
  }
});

// node_modules/ipp/ipp.js
var require_ipp = __commonJS({
  "node_modules/ipp/ipp.js"(exports, module) {
    var util = require_ipputil();
    module.exports = {
      parse: require_parser(),
      serialize: require_serializer(),
      request: require_request(),
      Printer: require_printer(),
      versions: require_versions(),
      attributes: require_attributes(),
      keywords: require_keywords(),
      enums: require_enums(),
      tags: require_tags(),
      statusCodes: require_status_codes()
    };
    module.exports.operations = module.exports.enums["operations-supported"];
    module.exports.attribute = {
      //http://www.iana.org/assignments/ipp-registrations/ipp-registrations.xml#ipp-registrations-7
      groups: util.xref(module.exports.tags.lookup.slice(0, 15)),
      //http://www.iana.org/assignments/ipp-registrations/ipp-registrations.xml#ipp-registrations-8
      values: util.xref(module.exports.tags.lookup.slice(16, 31)),
      //http://www.iana.org/assignments/ipp-registrations/ipp-registrations.xml#ipp-registrations-9
      syntaxes: util.xref(module.exports.tags.lookup.slice(32))
    };
  }
});

// entry.js
var import_ipp = __toESM(require_ipp());
var entry_default = import_ipp.default;
var Printer = import_ipp.default.Printer;
export {
  Printer,
  entry_default as default
};

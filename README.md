# discourse-fcm-notifications
Plugin for having Discourse deliver push notifications to your custom iOS/Android app through Firebase.

This assumes you have a custom app that includes access to your Discourse forum. It won't work without such an app. If you don't have an app, I've designed a [basic app](https://payhip.com/b/3Dplj) that will let users browse your Discourse forum and receive push notifications, but submitting an app to the App Store and Google Play Store is not super simple. Alternatively, you can use the Discourse Pushover Notifications plugin instead, but then it's two clicks for users to go from a notification to your forum.

# Installation

See [the plugin install readme](https://meta.discourse.org/t/install-plugins-in-discourse/19157).

Create a Google Firebase project for your app. Add the Firebase project ID, token and the json (with OAuth data) to the plugin settings in your Discourse installation.

Your app can activate push notifications for the active user by sending the device token to YOUR_FORUM.com/fcm_notifications/automatic_subscribe?token=... . Be sure to call this every time the device token changes. To deactivate push notifications for the active user, call YOUR_FORUM.com/fcm_notifications/automatic_subscribe?token=REMOVE . 

Alternatively, you can have users copy-paste their device tokens in their preference -> Notifications. 

# Receiving push notifications in your app

The push notifications that this app creates will include:

````
'data': {
  "linked_obj_type" => 'link',
  "linked_obj_data" => <url to the post/message referenced in the message>,
},
'notification': {
  title: <something like "USERNAME sent you a private message in TOPIC">,
  body: <beginning of the message>,
}
````

So you need to display the push notification with title/body and tapping on it should open the URL from linked_obj_data in an in-app browser. 

## Sorumatik mobile answer compatibility

This fork is maintained at
[`ozkanceng/discourse-fcm-notifications`](https://github.com/ozkanceng/discourse-fcm-notifications).
Install it together with the protocol-2 release of
[`ozkanceng/discourse-sorumatik-ocr`](https://github.com/ozkanceng/discourse-sorumatik-ocr).

Posts marked `client_edge_solve=true` and `mobile_answer_protocol>=2` are
owned by the mobile application. The native AI adapter neither starts
generation nor publishes streaming snapshots for those posts. Saving the
completed answer still triggers the normal notification jobs. Legacy web
streaming remains optional and disabled by default.

Update this fork before enabling protocol 2 in the OCR plugin, then rebuild
Discourse. Rails integration specifications are included under
`spec/lib/ai_answer_streaming_spec.rb`; they require a Discourse test environment.

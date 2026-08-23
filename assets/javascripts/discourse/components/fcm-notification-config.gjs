import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { Input } from "@ember/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import { i18n } from "discourse-i18n";
import {
  subscribe as subscribeFcmNotification,
  unsubscribe as unsubscribeFcmNotification,
} from "discourse/plugins/discourse-fcm-notifications/discourse/lib/fcm-notifications";

export default class FcmNotificationConfig extends Component {
  @service currentUser;
  @service siteSettings;

  @tracked errorMessage = null;
  @tracked fcmNotificationSubscribed = null;
  @tracked loading = false;
  @tracked subscription = "";

  constructor() {
    super(...arguments);

    this.calculateSubscribed();
  }

  get showFcmNotification() {
    return this.siteSettings.fcm_notifications_enabled;
  }

  get disabled() {
    return !this.subscription || this.loading;
  }

  get instructions() {
    return trustHTML(i18n("discourse_fcm_notifications.instructions"));
  }

  calculateSubscribed() {
    this.fcmNotificationSubscribed =
      this.currentUser.custom_fields.discourse_fcm_notifications != null;
  }

  @action
  async subscribe() {
    this.loading = true;
    this.errorMessage = null;

    try {
      const response = await subscribeFcmNotification(this.subscription);

      if (response.success) {
        this.currentUser.custom_fields.discourse_fcm_notifications =
          this.subscription;
        this.calculateSubscribed();
      } else {
        this.errorMessage = response.error;
      }
    } finally {
      this.loading = false;
    }
  }

  @action
  async unsubscribe() {
    this.loading = true;
    this.errorMessage = null;

    try {
      const response = await unsubscribeFcmNotification();

      if (response.success) {
        this.currentUser.custom_fields.discourse_fcm_notifications = null;
        this.calculateSubscribed();
      } else {
        this.errorMessage = response.error;
      }
    } finally {
      this.loading = false;
    }
  }

  <template>
    {{#if this.showFcmNotification}}
      <div class="control-group fcm-notifications">
        <label class="control-label">
          {{i18n "discourse_fcm_notifications.title"}}
        </label>

        {{#if this.errorMessage}}
          <div class="alert alert-error">{{this.errorMessage}}</div>
        {{/if}}

        <div class="controls">
          <div>
            {{#if this.fcmNotificationSubscribed}}
              <DButton
                @icon="bell-slash-o"
                @label="discourse_fcm_notifications.disable"
                @action={{this.unsubscribe}}
                @disabled={{this.loading}}
              />
              <DConditionalLoadingSpinner
                @size="small"
                @condition={{this.loading}}
              />
            {{else}}
              <Input
                @value={{this.subscription}}
                disabled={{this.loading}}
                placeholder={{i18n
                  "discourse_fcm_notifications.api_key_placeholder"
                }}
              />
              <DButton
                @icon="bell-o"
                @label="discourse_fcm_notifications.enable"
                @action={{this.subscribe}}
                @disabled={{this.disabled}}
              />
              <DConditionalLoadingSpinner
                @size="small"
                @condition={{this.loading}}
              />
              <div class="instructions">{{this.instructions}}</div>
            {{/if}}
          </div>
        </div>
      </div>
    {{/if}}
  </template>
}

import { createActionTypesOf } from '../utils/helpers';
import { validateDNS, validateNetwork } from './../shared/services/service.validate'

export const CHANGE_NETWORKOPTIONS_ITEMS = createActionTypesOf("CHANGE_NETWORKOPTIONS_ITEMS")

export const changeNetworkOptionsItems = (name, value, isTouched) => {
  switch (name) {
    case "network": {
      var isValid = true

      if (value.length > 0)
        value.map(item => {
          if (!validateNetwork(item.value))
            isValid = false

          return null;
        })

      const validString = !isValid
        ? 'Please enter a valid value: (userinfo@  IP address ":" port )"'
        : ""

      return {
        type: CHANGE_NETWORKOPTIONS_ITEMS.REQUEST,
        payload: { name, value, isTouched, isValid, validString },
      }
    }
    case "dns": {
      var isValid = true

      if (value.length > 0)
        value.map(item => {
          if (!validateDNS(item.value))
            isValid = false

          return null;
        })

      const validString = !isValid
        ? 'Invalid input value, please see the tooltip for requirements'
        : ""

      return {
        type: CHANGE_NETWORKOPTIONS_ITEMS.REQUEST,
        payload: { name, value, isTouched, isValid, validString },
      }
    }
    default: {
      const isValid = true
      const validString = ""

      return {
        type: CHANGE_NETWORKOPTIONS_ITEMS.REQUEST,
        payload: { name, value, isTouched, isValid, validString },
      }
    }
  }
}

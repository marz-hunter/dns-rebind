import React, { Component } from "react";
import {
  Button,
  Form,
  Grid,
  Header,
  Message,
  Segment,
  Icon
} from "semantic-ui-react";
import {
  BrowserRouter as Router,
  Routes,
  Route,
  Link,
  Navigate
} from "react-router-dom";

class Login extends Component {
  constructor(props) {
    super(props);
  }

  state = {
    loginError: false
  };

  LoginForm() {
    return (
      <Grid
        textAlign="center"
        style={{ height: "100vh" }}
        verticalAlign="middle"
      >
        <Grid.Column style={{ maxWidth: 450 }}>
          <Header
            as="h2"
            color="black"
            textAlign="center"
            inverted
          >
            Log-in to your account
          </Header>
          <Form size="large" id="loginForm" inverted>
            {this.state.loginError && (
              <Message color="red" icon>
                <Icon name="ban" />
                Incorrect Username or Password
              </Message>
            )}
            <Segment stacked inverted>
              <Form.Input
                fluid
                icon="user"
                iconPosition="left"
                placeholder="Username"
                id="username"
              />
              <Form.Input
                fluid
                icon="lock"
                iconPosition="left"
                placeholder="Password"
                type="password"
                id="password"
              />

              <Button
                primary
                onClick={this.postLogin}
                fluid
                inverted
                size="large"
              >
                Login
              </Button>
              <br />
              <Grid>
                <Grid.Column>
                  <Link to="/signup">
                    <Button
                      style={{ maxWidth: 300 }}
                      size="medium"
                      inverted
                    >
                      Sign up
                    </Button>
                  </Link>
                </Grid.Column>
              </Grid>
            </Segment>
          </Form>
        </Grid.Column>
      </Grid>
    );
  }

  postLogin = event => {
    event.preventDefault();

    let email = document.getElementById("username").value;
    let password = document.getElementById("password").value;
    var data = new FormData();
    data.append("username", email);
    data.append("password", password);

    fetch(process.env.REACT_APP_API+"/auth/login", {
      method: "POST",
      headers: new Headers({
        // 'Content-Type': 'form-data',
      }),
      body: data
    })
      .then(res => res.json())
      .then(data => {
        if (data.error != null) {
          this.invalidCredenitals();
        } else {
          localStorage.setItem("access_token", data.access_token);
          this.props.setUser(data);
        }
      })
      .catch(err => {
        console.log(err);
      });
  };

  invalidCredenitals = () => {
    this.setState({
      loginError: true
    });
  };

  render() {
    return <div>{this.LoginForm()}</div>;
  }
}

export default Login;

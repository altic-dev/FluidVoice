import { expect } from 'expect';
import { Test, TestingModule } from '@nestjs/testing';
import { AppModule } from '../app.module';
import { getRepository } from 'typeorm';
import { User } from '../entity/user.entity';

describe('Regression Test Suite', () => {
  let module: TestingModule;
  let userRepository: any;

  beforeEach(async () => {
    module = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    userRepository = getRepository(User);
  });

  afterEach(async () => {
    await module.close();
  });

  it('should test user entity', async () => {
    // Arrange
    const user = new User();
    user.name = 'John Doe';

    // Act
    const result = await userRepository.save(user);

    // Assert
    expect(result.name).toBe('John Doe');
    expect(result).toBeTruthy(); // Ensure result is not null or undefined
  });
});